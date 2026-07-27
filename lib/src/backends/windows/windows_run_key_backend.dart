import 'dart:io';

import '../../autostart_backend.dart';
import '../../autostart_config.dart';
import '../../exceptions.dart';
import '../../list_equals.dart';
import 'registry.dart';
import 'run_command_line.dart';
import 'startup_approval.dart';

/// The registry key Windows reads at login to start per-user programs.
const runKeyPath = r'Software\Microsoft\Windows\CurrentVersion\Run';

/// Registers a program at login through the registry `Run` key.
///
/// This is the simplest of the two Windows mechanisms: no elevation, no
/// external process, one value. Its cost is that a console-subsystem
/// executable — anything from `dart compile exe` — shows a console window at
/// every login, and the subsystem is fixed at compile time so nothing at
/// runtime can suppress it.
final class WindowsRunKeyBackend implements AutostartBackend {
  /// Creates a backend for [config].
  ///
  /// [runKey] is the single seam: tests point it at a scratch subkey and run
  /// the real advapi32 calls against it.
  const WindowsRunKeyBackend({
    required this.config,
    this.runKey = const RegistryLocation(path: runKeyPath),
    this.approvalKey = const RegistryLocation(path: startupApprovedRunKeyPath),
    this.registry = const WindowsRegistry(),
  });

  /// What to register.
  final AutostartConfig config;

  /// Where the registration is stored.
  final RegistryLocation runKey;

  /// Where Windows records the user's own decision about the entry.
  final RegistryLocation approvalKey;

  /// How the registry is reached.
  final WindowsRegistry registry;

  /// Registers the executable, and clears any veto the user had set.
  ///
  /// Writing the approval value overrides a user who switched this entry off in
  /// Task Manager. That is the behaviour `launch_at_startup` has, adopted
  /// deliberately and recorded in `docs/agents/theflow.md` as the maintainer's
  /// call — the calling application is expected to have asked its user first.
  @override
  Future<void> enable() async {
    if (!File(config.executablePath).existsSync()) {
      throw ExecutableNotFoundException(config.executablePath);
    }

    // Neither order is clearly safer here, unlike in `disable()`. A crash after
    // the first write leaves either a registration still under a standing veto,
    // or an approval value with nothing registered — both inert, and both
    // repaired by the next `enable()`, which rewrites the pair. Registration
    // first only because it is the value that matters if the pair ever drifts.
    registry
      ..writeString(runKey, config.appName, _canonicalValue)
      ..writeBinary(approvalKey, config.appName, enabledApprovalValue());
  }

  /// Removes this application's registration, and only this application's.
  ///
  /// The `Run` key is a **shared namespace keyed by value name**, and the name
  /// comes from caller-supplied text. Deleting on a name match alone would
  /// destroy another application's autostart with no way back.
  ///
  /// The guard is that the stored entry must **name the configured
  /// executable**. Recognising the *format* is not enough: quoting the path is
  /// what every well-behaved installer does, not a signature of this package —
  /// checked against a real machine, six of six third-party `Run` entries were
  /// in the same shape this package writes. Only the path identifies an entry
  /// as belonging to this application.
  ///
  /// The cost is that a registration left behind by an **earlier install at a
  /// different path** is not cleaned up here; `enable()` overwrites it, and a
  /// user can clear it from Task Manager. That is the safe direction to fail:
  /// one stale entry beats deleting a third party's.
  ///
  /// The same guard governs the approval value, which means **an approval value
  /// whose registration is already gone is left alone**. It cannot be attributed:
  /// under a name we do not currently own it might be this application's own
  /// leftover, or a third party's — and a third party's would be the *user's
  /// veto of that application*, which clearing would silently turn back on
  /// something they switched off. An orphan is inert while no registration
  /// exists, and this package's own `enable()` overwrites it, so the untidy
  /// outcome is the one that cannot hurt anybody.
  @override
  Future<void> disable() async {
    if (!await _isOurs()) return;

    // Order matters here, and the other way round from `enable()`. The
    // registration goes first because an approval value with no registration is
    // inert, while a registration with no approval value is *enabled* — so
    // deleting the approval first would, for the moment between the two calls,
    // turn autostart back on.
    registry
      ..deleteValue(runKey, config.appName)
      ..deleteValue(approvalKey, config.appName);
  }

  /// Whether the executable will actually launch at login.
  ///
  /// Two separate stores have to agree. The registration says what this
  /// application asked for; the approval value says what the user allowed, and
  /// the user can change it from Task Manager without this package ever seeing
  /// it. An answer based on the registration alone reports "on" for an entry
  /// that will never run.
  @override
  Future<bool> isEnabled() async {
    final decoded = _decodeStored();
    if (decoded == null) return false;

    if (!_samePath(decoded.executablePath, config.executablePath)) return false;
    if (!listEquals(decoded.args, config.args)) return false;

    return isStartupApproved(registry.readBinary(approvalKey, config.appName));
  }

  /// Whether the stored entry belongs to this application.
  ///
  /// Weaker than [isEnabled] on purpose: the arguments may have changed between
  /// releases, and an entry this application owns is still its own to remove.
  Future<bool> _isOurs() async {
    final decoded = _decodeStored();
    if (decoded == null) return false;
    return _samePath(decoded.executablePath, config.executablePath);
  }

  RunCommandLine? _decodeStored() {
    final stored = registry.readString(runKey, config.appName);
    if (stored == null) return null;
    return decodeRunCommandLine(stored);
  }

  String get _canonicalValue =>
      encodeRunCommandLine(config.executablePath, config.args);

  // Windows paths are case-insensitive, so an entry written as `C:\App\app.exe`
  // launches the same file as `c:\app\APP.exe`. Comparing them exactly would
  // report "off" for a registration that works, which is a worse lie than the
  // theoretical case-sensitive filesystem this ignores.
  static bool _samePath(String a, String b) =>
      a.toLowerCase() == b.toLowerCase();
}
