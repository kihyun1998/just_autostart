/// Launch a Dart command-line program or daemon when the user logs in.
///
/// Pure Dart: no Flutter dependency, and no native sources to compile.
/// Windows and macOS are the platforms this package targets. A platform with no
/// backend raises [UnsupportedPlatformException] rather than quietly doing
/// nothing.
///
/// No platform backend is wired up yet, so at this version *every* operating
/// system raises [UnsupportedPlatformException].
library;

export 'src/autostart.dart';
export 'src/autostart_backend.dart';
export 'src/autostart_config.dart';
export 'src/autostart_platform.dart';
export 'src/backends/unsupported_backend.dart';
export 'src/exceptions.dart';
