import 'dart:io';

import 'package:just_autostart/just_autostart.dart';

/// Where your installer put the compiled binary.
///
/// Deliberately a literal rather than `Platform.resolvedExecutable`: run this
/// file with `dart run` and that getter returns the path of the Dart runtime,
/// which is exactly the trap the package refuses to fall into on your behalf.
const executablePath = r'C:\Program Files\My Tool\mytool.exe';

/// Reports what `just_autostart` would do on the platform this runs on.
///
/// On Windows this reads the real registration state. On macOS — not yet
/// implemented — and on every other platform it prints the failure from the
/// unsupported backend.
///
/// It only *reads*: an example that registered itself at login would be a
/// surprising thing to run.
Future<void> main() async {
  final config = AutostartConfig(
    appName: 'My Tool',
    label: 'com.example.mytool',
    // The package never infers this: under `dart pub global activate`,
    // Platform.resolvedExecutable points at the Dart runtime rather than at
    // your tool. It is correct here because this example is run directly.
    executablePath: Platform.resolvedExecutable,
    args: const ['--daemon'],
  );

  final autostart = Autostart.forCurrentPlatform(config);

  try {
    stdout.writeln('enabled: ${await autostart.isEnabled()}');
  } on UnsupportedPlatformException catch (error) {
    stdout.writeln(error.message);
  }
}
