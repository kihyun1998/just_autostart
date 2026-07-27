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
/// macOS is not implemented yet and currently raises
/// [UnsupportedPlatformException] like any other platform.
library;

export 'src/autostart.dart';
export 'src/autostart_backend.dart';
export 'src/autostart_config.dart';
export 'src/autostart_platform.dart';
export 'src/backends/unsupported_backend.dart';
export 'src/exceptions.dart';
export 'src/windows_options.dart';
