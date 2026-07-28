/// Launch a Dart command-line program or daemon when the user logs in.
///
/// Pure Dart: no Flutter dependency, and no native sources to compile.
/// Windows and macOS are the platforms this package targets. A platform with no
/// backend raises [UnsupportedPlatformException] rather than quietly doing
/// nothing.
///
/// Windows offers two mechanisms — the registry `Run` key and Task Scheduler —
/// and the calling application chooses between them with
/// [WindowsAutostartOptions]. Only Task Scheduler can start a program built by
/// `dart compile exe` without a console window appearing at every login.
///
/// macOS registers a launchd user agent — a property list in the user's
/// `LaunchAgents` directory — with no FFI and no dependencies.
library;

export 'src/autostart.dart';
export 'src/autostart_backend.dart';
export 'src/autostart_config.dart';
export 'src/autostart_platform.dart';
// The macOS backend is exported where the Windows ones are not, because it
// carries one operation the cross-platform surface cannot: `isRunningNow()`,
// which reports whether immediate activation actually started the agent. A
// caller who asked for that has no other way to reach the answer.
export 'src/backends/macos/macos_autostart_backend.dart';
export 'src/backends/unsupported_backend.dart';
export 'src/exceptions.dart';
export 'src/macos_options.dart';
export 'src/windows_options.dart';
