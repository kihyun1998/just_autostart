import 'dart:io';

import '../../autostart_backend.dart';
import '../../autostart_config.dart';
import '../../exceptions.dart';
import '../../list_equals.dart';
import '../../macos_options.dart';
import 'launch_agent_plist.dart';
import 'launchctl.dart';

/// Registers a program at login through a launchd **user agent**.
///
/// The registration is a property list file in the user's `LaunchAgents`
/// directory, written with `dart:io`. launchd scans that directory at login, so
/// writing the file is enough to start the program at the next login — no
/// `launchctl` call, no FFI, and no dependency. The mechanism is a LaunchAgent
/// rather than `SMAppService` because a `dart compile exe` output is a bare
/// Mach-O with no `.app` bundle for that API to register.
///
/// The launchd job label doubles as the file name (`<label>.plist`), so the two
/// always agree. [AutostartConfig] rejects a label containing a path separator,
/// which is what stops the file name from escaping this directory.
final class MacosAutostartBackend implements AutostartBackend {
  /// Creates a backend for [config].
  ///
  /// [launchAgentsDirectory] is the single seam: tests point it at a temporary
  /// directory and the real file-writing code runs against it. It defaults to
  /// `~/Library/LaunchAgents`, resolved when an operation runs rather than at
  /// construction, so a caller can build the backend before deciding to use it.
  const MacosAutostartBackend({
    required this.config,
    Directory? launchAgentsDirectory,
    this.launchctl = const SystemLaunchctl(),
    this.options = const MacosAutostartOptions(),
  }) : _launchAgentsDirectory = launchAgentsDirectory;

  /// What to register.
  final AutostartConfig config;

  /// How launchd should run it — the optional agent settings.
  ///
  /// Every unset value is left out of the plist entirely, so the default
  /// instance produces the minimal agent.
  final MacosAutostartOptions options;

  /// Reads and clears the user's launchd disable overrides — the second store,
  /// separate from the plist, that records a Login Items veto.
  final Launchctl launchctl;

  final Directory? _launchAgentsDirectory;

  /// The directory the agent's plist is written into.
  ///
  /// The injected value in a test, or `~/Library/LaunchAgents` in production.
  Directory get launchAgentsDirectory =>
      _launchAgentsDirectory ?? _defaultLaunchAgentsDirectory();

  File get _plistFile =>
      File('${launchAgentsDirectory.path}/${config.label}.plist');

  /// Writes the launch agent so the executable starts at login.
  ///
  /// Idempotent: the file is written whole every time, so enabling something
  /// already enabled leaves exactly one well-formed agent. Rejects an executable
  /// that does not exist, because the alternative is a registration that looks
  /// successful and silently launches nothing at the user's next login.
  ///
  /// It also **clears the user's Login-Items veto** — the launchd disable
  /// override that lives outside the plist, recording that the user switched the
  /// agent off in System Settings. Overriding that veto matches the package's
  /// boundary rule (the calling application is expected to have asked its user
  /// first) and keeps the platforms symmetric with Windows, which rewrites its
  /// approval byte on every `enable()`. Clearing it via `launchctl enable` was
  /// measured to succeed unprivileged on macOS 14.5 (see `docs/agents/theflow.md`).
  ///
  /// If the veto still stands after the attempt — the clear failed *and* the
  /// override is confirmed present — `enable()` throws rather than returning a
  /// success that a following `isEnabled()` would contradict. A launchctl that
  /// cannot be read at all degrades to "no veto known", the same as
  /// [isEnabled], so the two never disagree.
  @override
  Future<void> enable() async {
    final executable = File(config.executablePath);
    if (!executable.existsSync()) {
      throw ExecutableNotFoundException(config.executablePath);
    }
    // Existence is not launchability: a file with no execute bit passes the
    // check above but fails execvp at login. 0x49 is the owner/group/other
    // execute bits; none set means the file cannot run for anyone.
    if (executable.statSync().mode & 0x49 == 0) {
      throw ExecutablePermissionException(config.executablePath);
    }

    final xml = generateLaunchAgentPlist(
      label: config.label,
      executablePath: config.executablePath,
      args: config.args,
      keepAlive: options.keepAlive,
      standardOutPath: options.standardOutPath,
      standardErrorPath: options.standardErrorPath,
      workingDirectory: options.workingDirectory,
      environment: options.environment,
    );

    try {
      launchAgentsDirectory.createSync(recursive: true);
      _plistFile.writeAsStringSync(xml);
    } on FileSystemException catch (error) {
      throw AutostartOsException(
        operation: 'write the LaunchAgent plist',
        detail: error.message,
        errorCode: error.osError?.errorCode,
      );
    }

    _restrictPermissions(_plistFile);

    launchctl.clearOverride(config.label);
    if (_isVetoedByUser()) {
      throw AutostartOsException(
        operation: 'clear the Login Items veto for "${config.label}"',
        detail:
            'the user switched this agent off in System Settings and the veto '
            'could not be cleared',
      );
    }

    if (options.activateImmediately) _activate();
  }

  /// Clears the group and other **write** bits on the written agent.
  ///
  /// launchd refuses a job definition that anyone but its owner can write, and
  /// the refusal is **silent**: the file stays in `LaunchAgents`, parses, and
  /// nothing launches. `File.writeAsStringSync` takes whatever the process
  /// umask gives it — `0644` under the usual `0022`, but `0666` under `umask 0`
  /// and `0664` under `umask 002`, both of which occur in build systems and
  /// containers. Measured on macOS 14.5: the same plist loads at `0644` and
  /// fails with `Bootstrap failed: 5: Input/output error` at `0666`.
  ///
  /// It clears those two bits rather than forcing `0644`, so a caller who
  /// deliberately made the agent `0600` keeps it private.
  ///
  /// `dart:io` has no `chmod`, so this shells out like the `launchctl` calls do
  /// — still no native code. A failure to restrict is raised rather than
  /// ignored: the registration would otherwise be one launchd will not load.
  void _restrictPermissions(File file) {
    final ProcessResult result;
    try {
      result = Process.runSync('chmod', ['go-w', file.path]);
    } on ProcessException catch (error) {
      throw AutostartOsException(
        operation: 'restrict permissions on the LaunchAgent plist',
        detail: error.message,
      );
    }

    if (result.exitCode != 0) {
      throw AutostartOsException(
        operation: 'restrict permissions on the LaunchAgent plist',
        detail: '${result.stderr}'.trim(),
        errorCode: result.exitCode,
      );
    }
  }

  /// Whether [file] is writable by group or other, which makes launchd refuse
  /// it — see [_restrictPermissions].
  ///
  /// `0x10` is the group-write bit and `0x2` the other-write bit.
  static bool _isWorldWritable(File file) {
    final mode = file.statSync().mode;
    return mode & 0x10 != 0 || mode & 0x2 != 0;
  }

  /// Starts the agent in the current session, replacing a job already loaded
  /// under this label.
  ///
  /// The bootout comes first for two measured reasons: `launchctl bootstrap`
  /// **fails** when the label is already loaded, which is the ordinary
  /// repeat-`enable()` path; and a job loaded from an earlier `enable()` keeps
  /// running the *old* configuration, so re-loading is what makes a changed
  /// executable or argument list take effect now.
  ///
  /// Nothing here throws. Both commands report failure in situations that are
  /// not failures at all (nothing was loaded; the session is not a GUI one),
  /// and the registration this method follows has already succeeded — the agent
  /// starts at the next login whatever happens here. [isRunningNow] is how a
  /// caller learns the outcome.
  void _activate() {
    launchctl
      ..bootout(config.label)
      ..bootstrap(_plistFile.path);
  }

  /// Whether the agent is loaded into the **current** login session.
  ///
  /// Distinct from [isEnabled], which answers "will it start at the next
  /// login". A caller that asked for [MacosAutostartOptions.activateImmediately]
  /// uses this to find out whether starting it now actually worked — the outcome
  /// `enable()` deliberately does not throw for.
  ///
  /// What it reports precisely is that launchd **has the job**, which is the
  /// answer to "did activation take". It is not a liveness check on the
  /// process: a program that has already run and exited leaves its job loaded,
  /// so this stays true for a short-lived program that is no longer executing.
  /// For the long-running daemons this option exists to serve the two coincide;
  /// where they do not, the process's own health is the application's to
  /// observe, not something launchd's registration can tell it.
  ///
  /// Read from launchd rather than remembered from the attempt, for the same
  /// reason [isEnabled] reads the operating system rather than a stored
  /// preference: the session can change without this package seeing it.
  Future<bool> isRunningNow() async => launchctl.isLoaded(config.label);

  /// Removes this application's launch agent, if one is present.
  ///
  /// Idempotent: removing what was never written is not an error.
  ///
  /// The `LaunchAgents` directory is a **shared namespace**, and — critically —
  /// launchd identifies a job by the `Label` **inside** the file, not by the
  /// file name. A third party's plist can legally sit at `<our-label>.plist`
  /// while belonging to a different agent, so deleting on the file name alone
  /// would destroy their registration with no way back (a sacred path). The
  /// guard is that the file's internal `Label` must equal ours before it is
  /// removed. A file we cannot read as ours — a foreign label, or a plist too
  /// corrupt to parse — is left in place rather than deleted or raised.
  ///
  /// Matching the label rather than the path means a registration whose binary
  /// *moved* is still ours to remove — it is the same launchd job — which is the
  /// registration `enable()` would otherwise leave running.
  @override
  Future<void> disable() async {
    final file = _plistFile;
    if (!file.existsSync()) return;
    if (!_isOurs(file)) return;

    // Before the file goes: `launchctl bootout` names a job launchd resolved
    // from this plist, so deleting it first would leave a running job with
    // nothing to unload it by until the next login. The ownership guard above
    // governs this too — booting out a label this application does not own
    // would stop a third party's running agent.
    if (options.activateImmediately) launchctl.bootout(config.label);

    try {
      file.deleteSync();
    } on FileSystemException catch (error) {
      throw AutostartOsException(
        operation: 'remove the LaunchAgent plist',
        detail: error.message,
        errorCode: error.osError?.errorCode,
      );
    }
  }

  /// Whether [file] is the launch agent this application registered.
  ///
  /// Weaker than [isEnabled]: it asks only "is this our job", by the launchd
  /// identity (the internal `Label`), so a disabled or stale-but-ours agent is
  /// still ours to remove. A file too corrupt to parse is treated as not ours —
  /// the safe direction, since deleting an unreadable stranger's file is the
  /// harm this guard exists to prevent.
  bool _isOurs(File file) {
    try {
      return parseLaunchAgentPlist(file.readAsStringSync()).label ==
          config.label;
    } on MalformedRegistrationException {
      return false;
    }
  }

  /// Whether the configured executable will actually launch at login.
  ///
  /// Stricter than "a plist exists". Every condition below governs whether
  /// launchd will start the program, and all of them live inside the file this
  /// reads:
  ///
  /// - the plist exists (a missing one is "not registered" — false, not raised);
  /// - its `ProgramArguments` name the configured executable and arguments, so a
  ///   registration left pointing at an old binary reports false;
  /// - `RunAtLoad` is set, without which launchd loads the job but does not
  ///   start it at login;
  /// - the in-plist `Disabled` key is not set — a second store inside the same
  ///   file that suppresses the job independently of everything above.
  ///
  /// A plist that exists but is corrupt raises [MalformedRegistrationException]:
  /// it sits at this application's own label path, so it is a broken
  /// registration to surface, not a foreign entry to ignore.
  ///
  /// The final condition is the fourth store, and the only one *outside* the
  /// file: launchd's disable overrides, which record the user switching the
  /// agent off in System Settings. It is read through [launchctl]; a launchctl
  /// that cannot be read degrades to "no veto", so an OS change makes this
  /// slightly too optimistic rather than breaking the API.
  @override
  Future<bool> isEnabled() async {
    final file = _plistFile;
    if (!file.existsSync()) return false;

    final LaunchAgentPlist parsed;
    try {
      parsed = parseLaunchAgentPlist(file.readAsStringSync());
    } on MalformedRegistrationException catch (error) {
      // The pure parser has no path to name; attach ours so the caller can act
      // on the file the message points at.
      throw MalformedRegistrationException(error.detail, path: file.path);
    }

    // Exact comparison, not case-folded like Windows: a macOS volume can be
    // case-sensitive, and the path being compared is the one the caller passed
    // to both `enable()` and here, so it matches exactly in the normal case.
    if (parsed.executablePath != config.executablePath) return false;
    if (!listEquals(parsed.args, config.args)) return false;
    if (!parsed.runAtLoad) return false;
    if (parsed.disabled) return false;
    // A registration launchd will refuse is not an enabled one. Same class as
    // the two keys above — present, well formed, and inert. This catches a
    // plist written by an earlier version under a permissive umask, or one
    // whose permissions were changed after it was written.
    if (_isWorldWritable(file)) return false;
    if (_isVetoedByUser()) return false;

    return true;
  }

  /// Whether the user has switched this agent off in System Settings.
  ///
  /// Reads launchd's disable overrides through [launchctl]. A read that fails or
  /// returns an unrecognised format is treated as "not vetoed" — the veto has to
  /// be positively present to count, so a launchctl change degrades safely
  /// instead of reporting a working agent as off. `enable()` and [isEnabled] go
  /// through this same predicate, so they cannot disagree about the veto.
  bool _isVetoedByUser() {
    final overrides = launchctl.readDisabledOverrides();
    if (overrides == null) return false;
    return overridesDisableLabel(overrides, config.label);
  }

  static Directory _defaultLaunchAgentsDirectory() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw const AutostartOsException(
        operation: 'resolve the LaunchAgents directory',
        detail: 'the HOME environment variable is not set',
      );
    }
    return Directory('$home/Library/LaunchAgents');
  }
}
