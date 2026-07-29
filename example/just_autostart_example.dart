import 'dart:io';

import 'package:just_autostart/just_autostart.dart';

/// Where your installer put the compiled binary.
///
/// Deliberately a literal rather than `Platform.resolvedExecutable`: run this
/// file with `dart run` and that getter returns the path of the Dart runtime,
/// which is exactly the trap the package refuses to fall into on your behalf.
///
/// It does not have to exist for this example to be useful. Every call below
/// only *reads*, and a path that is not registered is answered `false` — which
/// is the honest answer and the one your own tool gets before its first
/// `enable()`.
const executablePath = r'C:\Program Files\My Tool\mytool.exe';

/// Reports what `just_autostart` would do on the platform this runs on.
///
/// On Windows and macOS this reads the real registration state. On every other
/// platform it prints the failure from the unsupported backend.
///
/// It only *reads*: an example that registered itself at login would be a
/// surprising thing to run.
Future<void> main() async {
  final config = AutostartConfig(
    appName: 'My Tool',
    label: 'com.example.mytool',
    // The package never infers this: under `dart pub global activate`,
    // `Platform.resolvedExecutable` points at the Dart runtime rather than at
    // your tool. So the path comes from above, where your installer would put
    // it — an example that reached for the getter would be demonstrating the
    // one practice this package exists to refuse.
    executablePath: executablePath,
    args: const ['--daemon'],
  );

  // The default mechanism on Windows is the registry `Run` key.
  await report('Run key', Autostart.forCurrentPlatform(config));

  // Task Scheduler is the opt-in, and the only mechanism that can start a
  // `dart compile exe` program without a console window appearing at login. The
  // choice is the calling application's — there is no automatic fallback.
  await report(
    'Task Scheduler',
    Autostart.forCurrentPlatform(
      config,
      windows: const WindowsAutostartOptions(
        mechanism: WindowsAutostartMechanism.taskScheduler,
        startupDelay: Duration(seconds: 30),
      ),
    ),
  );

  // On macOS the optional settings describe how launchd should run the agent.
  // A program started at login has no terminal and none of a login shell's
  // environment, so a daemon usually wants at least the log paths.
  final macos = Autostart.forCurrentPlatform(
    config,
    macos: const MacosAutostartOptions(
      keepAlive: true,
      standardOutPath: '/tmp/mytool.out',
      standardErrorPath: '/tmp/mytool.err',
      activateImmediately: true,
    ),
  );
  await report('launchd agent', macos);

  // `activateImmediately` is best-effort: the registration is written first, so
  // the agent starts at the next login whether or not it could also be started
  // right now. That outcome is asked for, not thrown.
  final backend = macos.backend;
  if (backend is MacosAutostartBackend) {
    stdout.writeln(
      'launchd agent — running in this session: '
      '${await backend.isRunningNow()}',
    );
  }
}

/// Prints what [autostart] currently reports, or why it cannot answer.
Future<void> report(String label, Autostart autostart) async {
  try {
    stdout.writeln('$label — enabled: ${await autostart.isEnabled()}');
  } on UnsupportedPlatformException catch (error) {
    stdout.writeln('$label — ${error.message}');
  }
}
