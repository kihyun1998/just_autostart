import 'dart:io';

import 'autostart_backend.dart';
import 'autostart_config.dart';
import 'autostart_platform.dart';
import 'backends/unsupported_backend.dart';
import 'backends/windows/windows_run_key_backend.dart';

/// Registers a program to launch when the user logs in.
///
/// ```dart
/// final autostart = Autostart.forCurrentPlatform(
///   AutostartConfig(
///     appName: 'My Tool',
///     label: 'com.example.mytool',
///     // Wherever your installer put the binary. See [AutostartConfig] for why
///     // this is not inferred for you.
///     executablePath: r'C:\Program Files\My Tool\mytool.exe',
///   ),
/// );
///
/// await autostart.enable();
/// ```
///
/// The platform backend is chosen once, when the instance is built. Operations
/// are delegated to it unchanged, so a backend's failures reach the caller
/// exactly as thrown.
class Autostart {
  /// Wraps a backend directly.
  ///
  /// Useful for tests, and for a caller who has constructed a platform backend
  /// with options the cross-platform surface does not expose.
  const Autostart.withBackend(this._backend);

  /// Builds the instance for the platform this program is running on.
  factory Autostart.forCurrentPlatform(AutostartConfig config) =>
      Autostart.forOperatingSystem(config, Platform.operatingSystem);

  /// Builds the instance for a named [operatingSystem].
  ///
  /// Takes the same values as `Platform.operatingSystem`. An operating system
  /// with no backend produces an instance whose every operation throws
  /// [UnsupportedPlatformException], rather than a failure at construction —
  /// so a caller can build one unconditionally and handle the failure at the
  /// point where autostart is actually requested.
  factory Autostart.forOperatingSystem(
    AutostartConfig config,
    String operatingSystem,
  ) => Autostart.withBackend(_backendFor(config, operatingSystem));

  final AutostartBackend _backend;

  /// Delegates to [AutostartBackend.enable].
  Future<void> enable() => _backend.enable();

  /// Delegates to [AutostartBackend.disable].
  Future<void> disable() => _backend.disable();

  /// Delegates to [AutostartBackend.isEnabled].
  Future<bool> isEnabled() => _backend.isEnabled();
}

AutostartBackend _backendFor(AutostartConfig config, String operatingSystem) {
  return switch (resolveAutostartPlatform(operatingSystem)) {
    // The registry `Run` key is the only Windows mechanism so far. Task
    // Scheduler, and the choice between the two, arrive with the mechanism
    // selector.
    AutostartPlatform.windows => WindowsRunKeyBackend(config: config),
    // The macOS backend is not built yet.
    AutostartPlatform.macos || AutostartPlatform.unsupported =>
      UnsupportedPlatformBackend(operatingSystem),
  };
}
