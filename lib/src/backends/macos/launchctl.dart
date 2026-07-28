import 'dart:io';

/// Reads and clears the user's launchd disable overrides through `launchctl`.
///
/// This is the macOS analogue of the Windows `StartupApproved` store: a
/// *second* place, separate from the registration, where the user's own veto
/// lives. Since macOS 13 a user can switch a login item off in System Settings,
/// which records a disable override in launchd's root-owned state without
/// touching the plist. A file-existence check therefore reports "enabled" for an
/// agent that will never run.
///
/// The seam exists because the override store cannot be pointed at a scratch
/// location the way a temporary `LaunchAgents` directory can — it is the live
/// machine state. Tests inject a fake; production uses [SystemLaunchctl].
abstract interface class Launchctl {
  /// The raw `launchctl print-disabled` output for the user's GUI domain, or
  /// `null` when the command could not be run or failed.
  ///
  /// A `null` is deliberately indistinguishable from "nothing is disabled" at
  /// the call site: a failed or unavailable `launchctl` degrades to the
  /// slightly-too-optimistic previous behaviour rather than breaking the API.
  String? readDisabledOverrides();

  /// Clears the disable override for [label] (`launchctl enable`), returning
  /// whether the command reported success.
  ///
  /// Measured to succeed for an unprivileged user in their own GUI domain on
  /// macOS 14.5; see `docs/agents/theflow.md`.
  bool clearOverride(String label);

  /// Loads the agent at [plistPath] into the current GUI session
  /// (`launchctl bootstrap`), so it starts now rather than at the next login.
  ///
  /// The returned value is the command's own report and is **not** a reliable
  /// answer on its own: bootstrapping an agent that is already loaded fails
  /// (measured: exit 5, `Bootstrap failed: 5: Input/output error`), which is
  /// the ordinary repeat-`enable()` path. Ask [isLoaded] for the truth.
  bool bootstrap(String plistPath);

  /// Removes [label] from the current GUI session (`launchctl bootout`).
  ///
  /// Same caveat as [bootstrap]: booting out an agent that is not loaded fails
  /// (measured: exit 3, `Boot-out failed: 3: No such process`), which is the
  /// ordinary repeat-`disable()` path rather than an error.
  bool bootout(String label);

  /// Whether [label] is currently loaded in the GUI session.
  ///
  /// This is the state the two commands above cannot be trusted to report, so
  /// it is what the backend answers callers with.
  bool isLoaded(String label);
}

/// The resolved `gui/<uid>` domain, remembered for the life of the process.
///
/// Top-level rather than a field because [SystemLaunchctl] is `const`: every
/// call site constructs its own instance, and they all describe the same
/// process, so the memo belongs to the process rather than to any one of them.
String? _cachedGuiDomain;

/// The real `launchctl`, driven with `dart:io` — no native code.
final class SystemLaunchctl implements Launchctl {
  /// Creates a launchctl driver targeting the current user's GUI domain.
  const SystemLaunchctl();

  @override
  String? readDisabledOverrides() {
    final domain = _guiDomain();
    if (domain == null) return null;
    return _run(['print-disabled', domain]);
  }

  @override
  bool clearOverride(String label) {
    final domain = _guiDomain();
    if (domain == null) return false;
    return _run(['enable', '$domain/$label']) != null;
  }

  @override
  bool bootstrap(String plistPath) {
    final domain = _guiDomain();
    if (domain == null) return false;
    return _run(['bootstrap', domain, plistPath]) != null;
  }

  @override
  bool bootout(String label) {
    final domain = _guiDomain();
    if (domain == null) return false;
    return _run(['bootout', '$domain/$label']) != null;
  }

  @override
  bool isLoaded(String label) {
    final domain = _guiDomain();
    if (domain == null) return false;
    return _run(['print', '$domain/$label']) != null;
  }

  /// `gui/<uid>`, or `null` if the uid could not be resolved.
  ///
  /// `dart:io` exposes no `getuid`, and this package takes no native code, so
  /// the uid comes from `id -u` — one more subprocess, not an FFI call.
  ///
  /// Resolved once and remembered for the life of the process. A process cannot
  /// change its own uid here, so re-running `id` per call bought nothing and
  /// cost a spawn: measured at **3,153 µs**, which was about 40% of
  /// `isEnabled()`'s 8,188 µs, paid again by every other launchctl operation.
  ///
  /// Only a **successful** resolution is remembered. Caching a failure would
  /// turn one bad moment — a process table too full to fork, say — into a
  /// permanent inability to read launchd for the rest of the run.
  String? _guiDomain() {
    final cached = _cachedGuiDomain;
    if (cached != null) return cached;

    try {
      final result = Process.runSync('id', ['-u']);
      if (result.exitCode != 0) return null;
      final uid = (result.stdout as String).trim();
      if (uid.isEmpty) return null;
      return _cachedGuiDomain = 'gui/$uid';
    } on ProcessException {
      return null;
    }
  }

  /// Runs `launchctl` with [args], returning stdout on success or `null` on any
  /// failure — a non-zero exit or `launchctl` being absent.
  String? _run(List<String> args) {
    try {
      final result = Process.runSync('launchctl', args);
      if (result.exitCode != 0) return null;
      return result.stdout as String;
    } on ProcessException {
      return null;
    }
  }
}

/// Whether [printDisabledOutput] records [label] as disabled by the user.
///
/// True for the label's veto value in either form the roster has used: the
/// macOS 13+ `"<label>" => disabled`, and the macOS 12-and-earlier
/// `"<label>" => true` (Ventura renamed the states). A label listed with the
/// corresponding "on" value (`enabled` / `false`), a label absent from the
/// output, and a value in neither vocabulary all yield `false` — the veto has to
/// be *positively* present to count, so an unreadable or future format degrades
/// to "not vetoed" rather than reporting a working agent as off.
///
/// (The pre-13 form is sourced from the documented format history, not
/// reproduced on a live pre-13 machine; it is inert on macOS 13+, where the
/// roster never prints `true`/`false`.)
///
/// The closing quote in the match anchors the label, so a name that is a prefix
/// of another (`com.apple.Siri` vs `com.apple.Siri.agent`) does not match it.
bool overridesDisableLabel(String printDisabledOutput, String label) {
  final match = RegExp(
    '"${RegExp.escape(label)}"\\s*=>\\s*(\\w+)',
  ).firstMatch(printDisabledOutput);
  final state = match?.group(1);
  return state == 'disabled' || state == 'true';
}
