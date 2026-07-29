/// A probe that calls `disable()` or `isEnabled()` against a FIFO planted at
/// the plist path.
///
/// It runs **in its own process**, and that indirection is the whole design.
/// `File.existsSync()` is true for a FIFO and `readAsStringSync` on one blocks
/// until a writer appears — a *synchronous* block, which freezes the isolate.
/// So the defect this probe detects cannot be asserted in-process: a
/// `Future.timeout` never fires, because the isolate is never given back to the
/// event loop to fire it. The test waits on this process instead, where a hang
/// is an observable exit code rather than a stuck suite.
///
/// Takes the scratch directory, the label, and which method to call. Exits 0 if
/// the call returned. If the regular-file guard is missing it simply never
/// exits, and the caller's timeout is the assertion.
library;

import 'dart:io';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/macos/launchctl.dart';

Future<void> main(List<String> args) async {
  final directory = Directory(args[0]);
  final label = args[1];
  final method = args[2];

  final backend = MacosAutostartBackend(
    config: AutostartConfig(
      appName: 'JustAutostartFifoProbe',
      label: label,
      executablePath: Platform.resolvedExecutable,
    ),
    launchAgentsDirectory: directory,
    launchctl: const _SilentLaunchctl(),
  );

  switch (method) {
    case 'disable':
      await backend.disable();
    case 'isEnabled':
      // The return value is the caller's assertion too: a FIFO is not a
      // registration, so this must be false rather than merely non-hanging.
      if (await backend.isEnabled()) exit(2);
    default:
      exit(3);
  }

  exit(0);
}

/// A launchctl that touches nothing, so the probe cannot mutate the real
/// session it is running in.
final class _SilentLaunchctl implements Launchctl {
  const _SilentLaunchctl();

  @override
  String? readDisabledOverrides() => null;

  @override
  bool clearOverride(String label) => true;

  @override
  bool bootstrap(String plistPath) => true;

  @override
  bool bootout(String label) => true;

  @override
  bool isLoaded(String label) => false;
}
