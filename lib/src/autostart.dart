import 'dart:io';

import 'autostart_backend.dart';
import 'autostart_config.dart';
import 'autostart_platform.dart';
import 'backends/macos/macos_autostart_backend.dart';
import 'backends/unsupported_backend.dart';
import 'backends/windows/windows_autostart_backend.dart';
import 'backends/windows/windows_run_key_backend.dart';
import 'backends/windows/windows_task_scheduler_backend.dart';
// Imported for the doc reference on `forOperatingSystem`: the exception is
// thrown by the unsupported backend rather than named in this file's code.
import 'exceptions.dart';
import 'macos_options.dart';
import 'windows_options.dart';

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
///
/// ## These calls block the isolate they are made on
///
/// [enable], [disable] and [isEnabled] return a `Future` that is **already
/// complete** when you receive it. Nothing here is deferred: the work is
/// `dart:ffi` and COM on Windows, `Process.runSync` and file I/O on macOS, and
/// `await`ing one of these never yields to the event loop.
///
/// How long that is depends on the mechanism, and the two differ by orders of
/// magnitude — the registry `Run` key is tens of microseconds, Task Scheduler
/// is milliseconds of RPC round trips. **Neither has an upper bound**, on
/// either platform, so no figure this package publishes is a ceiling.
///
/// A caller on a UI isolate that cannot afford the block moves the *whole*
/// operation off it:
///
/// ```dart
/// final enabled = await Isolate.run(() => autostart.isEnabled());
/// ```
///
/// That works because everything reachable from an [Autostart] is sendable, and
/// because each operation is one uninterrupted synchronous stretch — which is
/// also why it must be the whole call that moves, not something inside it. Two
/// costs come with it: the thrown trace carries only the worker's frames, not
/// yours, and a fake passed to [Autostart.withBackend] does not observe its own
/// mutations across the hop, because it is copied rather than shared.
/// `docs/adr/0003-what-this-packages-futures-promise.md` records why the
/// package does not take this hop for you.
class Autostart {
  /// Wraps a backend directly.
  ///
  /// Useful for tests, and for a caller who has constructed a platform backend
  /// with options the cross-platform surface does not expose.
  const Autostart.withBackend(this.backend);

  /// Builds the instance for the platform this program is running on.
  ///
  /// [windows] selects between the two Windows mechanisms and configures the
  /// one chosen. It is read only on Windows; passing it elsewhere is harmless
  /// and does nothing.
  factory Autostart.forCurrentPlatform(
    AutostartConfig config, {
    WindowsAutostartOptions windows = const WindowsAutostartOptions(),
    MacosAutostartOptions macos = const MacosAutostartOptions(),
  }) => Autostart.forOperatingSystem(
    config,
    Platform.operatingSystem,
    windows: windows,
    macos: macos,
  );

  /// Builds the instance for a named [operatingSystem].
  ///
  /// Takes the same values as `Platform.operatingSystem`. An operating system
  /// with no backend produces an instance whose every operation throws
  /// [UnsupportedPlatformException], rather than a failure at construction —
  /// so a caller can build one unconditionally and handle the failure at the
  /// point where autostart is actually requested.
  ///
  /// A [windows] combination that cannot be honoured — a startup delay asked of
  /// the registry `Run` key — throws [ArgumentError] here, because it is a
  /// mistake in the calling code rather than a condition of the machine, and
  /// because failing at construction is better than dropping the value
  /// silently.
  factory Autostart.forOperatingSystem(
    AutostartConfig config,
    String operatingSystem, {
    WindowsAutostartOptions windows = const WindowsAutostartOptions(),
    MacosAutostartOptions macos = const MacosAutostartOptions(),
  }) => Autostart.withBackend(
    _backendFor(config, operatingSystem, windows, macos),
  );

  /// The platform backend this instance delegates to.
  ///
  /// Exposed for symmetry with [Autostart.withBackend], and because "which
  /// mechanism did the selector actually choose" is a question a caller can
  /// otherwise only answer by watching the machine change.
  final AutostartBackend backend;

  /// Delegates to [AutostartBackend.enable].
  Future<void> enable() => backend.enable();

  /// Delegates to [AutostartBackend.disable].
  Future<void> disable() => backend.disable();

  /// Delegates to [AutostartBackend.isEnabled].
  Future<bool> isEnabled() => backend.isEnabled();
}

AutostartBackend _backendFor(
  AutostartConfig config,
  String operatingSystem,
  WindowsAutostartOptions windows,
  MacosAutostartOptions macos,
) {
  return switch (resolveAutostartPlatform(operatingSystem)) {
    AutostartPlatform.windows => _windowsBackend(config, windows),
    AutostartPlatform.macos => _macosBackend(config, macos),
    AutostartPlatform.unsupported => UnsupportedPlatformBackend(
      operatingSystem,
    ),
  };
}

AutostartBackend _macosBackend(
  AutostartConfig config,
  MacosAutostartOptions macos,
) {
  macos.validate();
  return MacosAutostartBackend(config: config, options: macos);
}

AutostartBackend _windowsBackend(
  AutostartConfig config,
  WindowsAutostartOptions windows,
) {
  windows.validate();

  final runKey = WindowsRunKeyBackend(config: config);
  final taskScheduler = WindowsTaskSchedulerBackend(
    config: config,
    hideWindow: windows.hideWindowOrDefault,
    delay: windows.startupDelay,
  );

  // Both are built either way. Constructing one costs nothing — no registry is
  // read and no COM apartment is opened until a method is called — and the
  // backend needs the one it did *not* choose in order to clean up after an
  // earlier version of the calling application that used it.
  return switch (windows.mechanism) {
    WindowsAutostartMechanism.runKey => WindowsAutostartBackend(
      chosen: runKey,
      other: taskScheduler,
    ),
    WindowsAutostartMechanism.taskScheduler => WindowsAutostartBackend(
      chosen: taskScheduler,
      other: runKey,
    ),
  };
}
