@TestOn('windows')
library;

import 'dart:io';

import 'package:just_autostart/src/backends/windows/task_scheduler.dart';
import 'package:test/test.dart';

/// The one claim this whole mechanism exists to make: a program Task Scheduler
/// starts with `HideAppWindow` has **no visible console window**.
///
/// It cannot be checked from inside the test process. `STARTUPINFO.wShowWindow`
/// is passed by whichever process calls `CreateProcess`, so the only way to
/// learn what the Task Scheduler service passed is to be the process it
/// launched. The probe is therefore registered as a real task, run through
/// `IRegisteredTask::Run`, and reports what it saw into a file.
///
/// Both mechanisms are exercised, and the **negative** case is what makes the
/// positive one mean anything: an assertion that a hidden window is hidden
/// would also pass if the probe simply never had a console.
const _scratchFolder = TaskFolder(r'\just_autostart_test_hidden_window');
const _scheduler = WindowsTaskScheduler(folder: _scratchFolder);

late Directory _scratch;

String _fullTaskName(String name) => '${_scratchFolder.path}\\$name';

/// Registers the probe, runs the task, and returns what the launched process
/// reported.
///
/// Returns `null` when the probe never wrote its file, which is a failure of
/// the harness rather than an answer about visibility.
String? runProbe({required bool hideWindow, required String name}) {
  final output = File('${_scratch.path}\\$name.txt');
  if (output.existsSync()) output.deleteSync();

  _scheduler.createTask(
    name,
    TaskRegistration(
      // The probe is a Dart script, so the executable is the Dart runtime and
      // the script is its first argument. That is also the shape of the console
      // window under test: `dart.exe` is a console-subsystem binary, exactly
      // like anything `dart compile exe` produces.
      executablePath: Platform.resolvedExecutable,
      args: [_probePath(), output.path],
      hideWindow: hideWindow,
    ),
  );

  final run = Process.runSync('schtasks', ['/run', '/tn', _fullTaskName(name)]);
  expect(run.exitCode, 0, reason: 'schtasks should have started the task');

  // The task runs asynchronously; the probe writes its file and exits. Polled
  // rather than slept once, so a slow machine does not turn into a flake and a
  // fast one does not pay for it.
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    if (output.existsSync()) {
      final text = output.readAsStringSync();
      if (text.isNotEmpty) return text;
    }
    sleep(const Duration(milliseconds: 200));
  }
  return null;
}

String _probePath() {
  final path = File('test/windows/hidden_window_probe.dart').absolute.path;
  expect(File(path).existsSync(), isTrue, reason: 'the probe should exist');
  return path;
}

void main() {
  setUpAll(() {
    _scratch = Directory.systemTemp.createTempSync('just_autostart_probe');
  });

  tearDownAll(() {
    _scheduler
      ..deleteTask('Hidden')
      ..deleteTask('Visible')
      ..deleteFolder();

    expect(
      Process.runSync('schtasks', [
        '/query',
        '/tn',
        _scratchFolder.path,
      ]).exitCode,
      isNot(0),
      reason: 'the scratch task folder should be gone',
    );

    if (_scratch.existsSync()) _scratch.deleteSync(recursive: true);
  });

  // Slow: each case registers a task, runs it, and waits for a real process to
  // start Dart and write a file.
  group(
    'a program started by a scheduled task',
    timeout: const Timeout(Duration(minutes: 3)),
    () {
      test('has no visible window when HideAppWindow is set', () {
        final report = runProbe(hideWindow: true, name: 'Hidden');

        expect(report, isNotNull, reason: 'the probe never wrote its report');
        expect(report, contains('visible=false'));
      });

      // The control. Without `HideAppWindow` the same probe, launched the same
      // way, reports a visible window — which is what proves the assertion
      // above is measuring the flag and not measuring "a task-launched process
      // never has a window".
      test('has a visible window without it', () {
        final report = runProbe(hideWindow: false, name: 'Visible');

        expect(report, isNotNull, reason: 'the probe never wrote its report');
        expect(report, contains('visible=true'));
      });

      // And the reason the assertion is written as `IsWindowVisible` rather
      // than as `GetConsoleWindow() != 0`: a hidden console still has a handle,
      // so the second question cannot tell the two cases apart.
      test('has a console window in both cases', () {
        expect(
          File('${_scratch.path}\\Hidden.txt').readAsStringSync(),
          contains('hasConsole=true'),
        );
        expect(
          File('${_scratch.path}\\Visible.txt').readAsStringSync(),
          contains('hasConsole=true'),
        );
      });
    },
  );
}
