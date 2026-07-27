@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/windows/current_user.dart';
import 'package:just_autostart/src/backends/windows/task_scheduler.dart';
import 'package:just_autostart/src/backends/windows/windows_task_scheduler_backend.dart';
import 'package:test/test.dart';

const _scratchFolder = TaskFolder(r'\just_autostart_test_ts_backend');
const _scheduler = WindowsTaskScheduler(folder: _scratchFolder);
const _taskName = 'JustAutostartTest';

/// A path that certainly exists, so `enable()` gets past its existence check.
final _realExecutable = Platform.resolvedExecutable;

WindowsTaskSchedulerBackend _backend({
  String? executablePath,
  List<String> args = const [],
  bool hideWindow = true,
  Duration? delay,
}) {
  return WindowsTaskSchedulerBackend(
    config: AutostartConfig(
      appName: _taskName,
      label: 'dev.justautostart.test',
      executablePath: executablePath ?? _realExecutable,
      args: args,
    ),
    hideWindow: hideWindow,
    delay: delay,
    scheduler: _scheduler,
  );
}

String _fullTaskName() => '${_scratchFolder.path}\\$_taskName';

bool schtasksSees() =>
    Process.runSync('schtasks', ['/query', '/tn', _fullTaskName()]).exitCode ==
    0;

/// Registers a task this package did **not** write, under the name it uses.
///
/// `schtasks` is the planting tool on purpose: a foreign entry created by our
/// own code would share whatever mistake our code has.
void plantForeignTask({String command = r'C:\Windows\System32\notepad.exe'}) {
  final result = Process.runSync('schtasks', [
    '/create',
    '/tn',
    _fullTaskName(),
    '/tr',
    command,
    '/sc',
    'ONCE',
    '/st',
    '23:59',
    '/f',
  ]);
  expect(result.exitCode, 0, reason: 'schtasks should have planted the task');
}

/// Whether a task folder exists, regardless of whether it holds any tasks.
///
/// **Not `schtasks /query /tn <folder>`**, which exits non-zero for a folder
/// that is absent *and* for one that is merely empty — so an assertion built on
/// it passes for the leftover it exists to catch. Task Scheduler stores folders
/// as real directories under `System32\Tasks`.
bool taskFolderExists(String path) =>
    Directory('${r'C:\Windows\System32\Tasks'}$path').existsSync();

void main() {
  _triggerStoreTests();

  setUp(() {
    _scheduler.deleteTask(_taskName);
  });

  tearDownAll(() {
    _scheduler
      ..deleteTask(_taskName)
      ..deleteFolder();

    expect(
      taskFolderExists(_scratchFolder.path),
      isFalse,
      reason: 'the scratch task folder should be gone',
    );
  });

  group('enable', () {
    test('registers a task so isEnabled reports it', () async {
      final backend = _backend();

      await backend.enable();

      expect(await backend.isEnabled(), isTrue);
      expect(schtasksSees(), isTrue);
    });

    test('is idempotent', () async {
      final backend = _backend();

      await backend.enable();
      await backend.enable();

      expect(await backend.isEnabled(), isTrue);
    });

    test('rejects an executable that does not exist', () {
      expect(
        _backend(executablePath: r'C:\nope\missing.exe').enable(),
        throwsA(
          isA<ExecutableNotFoundException>().having(
            (e) => e.executablePath,
            'executablePath',
            r'C:\nope\missing.exe',
          ),
        ),
      );
    });

    test('leaves nothing behind when it rejects the executable', () async {
      final backend = _backend(executablePath: r'C:\nope\missing.exe');

      await expectLater(backend.enable(), throwsA(anything));

      expect(schtasksSees(), isFalse);
    });

    test('registers the arguments it was configured with', () async {
      await _backend(args: const ['--daemon', '-v']).enable();

      expect(_scheduler.readTask(_taskName)!.args, ['--daemon', '-v']);
    });

    test('hides the window by default', () async {
      await _backend().enable();

      expect(_taskXml(), contains('<HideAppWindow>true<'));
    });

    test('leaves the window visible when the caller asks', () async {
      await _backend(hideWindow: false).enable();

      expect(_taskXml(), isNot(contains('<HideAppWindow>true<')));
    });

    test('carries the configured delay', () async {
      await _backend(delay: const Duration(seconds: 45)).enable();

      expect(_taskXml(), contains('<Delay>PT45S</Delay>'));
    });
  });

  group('isEnabled', () {
    test('is false when nothing is registered', () async {
      expect(await _backend().isEnabled(), isFalse);
    });

    test('is false when the task points elsewhere', () async {
      await _backend().enable();

      expect(
        await _backend(executablePath: r'C:\somewhere\else.exe').isEnabled(),
        isFalse,
      );
    });

    test('is false when the arguments differ', () async {
      await _backend(args: const ['--daemon']).enable();

      expect(await _backend(args: const ['--other']).isEnabled(), isFalse);
      expect(await _backend().isEnabled(), isFalse);
    });

    // Windows paths are case-insensitive, so a task registered as
    // `C:\App\app.exe` launches the same file as `c:\app\APP.exe`. Reporting
    // that as off would be a worse lie than ignoring the case-sensitive
    // filesystem nobody runs Windows on.
    test('is true when the path differs only in case', () async {
      await _backend().enable();

      expect(
        await _backend(
          executablePath: _realExecutable.toUpperCase(),
        ).isEnabled(),
        isTrue,
      );
    });

    // The second store. A user can switch a task off in the Task Scheduler UI
    // and the registration is left exactly as it was — reporting on the
    // registration alone says a program that will never run is enabled.
    test('is false once the user has switched the task off', () async {
      final backend = _backend();
      await backend.enable();

      final result = Process.runSync('schtasks', [
        '/change',
        '/tn',
        _fullTaskName(),
        '/disable',
      ]);
      expect(result.exitCode, 0);

      expect(await backend.isEnabled(), isFalse);
      expect(schtasksSees(), isTrue, reason: 'the task itself is untouched');
    });

    test('is true again once the user switches it back on', () async {
      final backend = _backend();
      await backend.enable();
      Process.runSync('schtasks', [
        '/change',
        '/tn',
        _fullTaskName(),
        '/disable',
      ]);
      Process.runSync('schtasks', [
        '/change',
        '/tn',
        _fullTaskName(),
        '/enable',
      ]);

      expect(await backend.isEnabled(), isTrue);
    });

    test('is false for a task this package did not write', () async {
      plantForeignTask();

      expect(await _backend().isEnabled(), isFalse);
    });
  });

  group('disable', () {
    test('removes a task this package wrote', () async {
      final backend = _backend();
      await backend.enable();

      await backend.disable();

      expect(await backend.isEnabled(), isFalse);
      expect(schtasksSees(), isFalse);
    });

    test('is idempotent', () async {
      final backend = _backend();
      await backend.enable();

      await backend.disable();
      await backend.disable();

      expect(schtasksSees(), isFalse);
    });

    test('does not error when nothing is registered', () async {
      await expectLater(_backend().disable(), completes);
    });

    // The sacred path. The task folder is a shared namespace and the task name
    // comes from caller-supplied text, so a name collision must never cost a
    // third party their scheduled task.
    test('leaves a third-party task in place', () async {
      plantForeignTask();

      await _backend().disable();

      expect(schtasksSees(), isTrue);
      expect(
        _scheduler.readTask(_taskName)!.executablePath!.toLowerCase(),
        contains('notepad.exe'),
      );
    });

    test(
      'leaves a third-party task whose path merely resembles ours',
      () async {
        // Same directory, different program: a guard that compared only the
        // folder, or only the file name, would delete this.
        plantForeignTask(command: r'C:\Windows\System32\calc.exe');

        await _backend(
          executablePath: r'C:\Windows\System32\notepad.exe',
        ).disable();

        expect(schtasksSees(), isTrue);
      },
    );

    // Ours by path, so ours to remove even though the arguments have changed.
    test('removes our task when only the arguments differ', () async {
      await _backend(args: const ['--old-flag']).enable();

      await _backend(args: const ['--new-flag']).disable();

      expect(schtasksSees(), isFalse);
    });

    // The cost of identifying tasks by path: one left by an earlier install at
    // a different location is not cleaned up here. Safe direction — `enable()`
    // overwrites it, and one stale task beats deleting a third party's.
    test('leaves behind a task registered at an older path', () async {
      await _backend(
        executablePath: r'C:\Windows\System32\notepad.exe',
      ).enable();

      await _backend().disable();

      expect(schtasksSees(), isTrue);
    });

    // A user's veto does not change whose task it is.
    test('removes our task even after the user disabled it', () async {
      final backend = _backend();
      await backend.enable();
      Process.runSync('schtasks', [
        '/change',
        '/tn',
        _fullTaskName(),
        '/disable',
      ]);

      await backend.disable();

      expect(schtasksSees(), isFalse);
    });
  });
}

String _taskXml() {
  final result = Process.runSync('schtasks', [
    '/query',
    '/tn',
    _fullTaskName(),
    '/xml',
    'ONE',
  ]);
  expect(result.exitCode, 0, reason: 'schtasks should have found the task');
  return result.stdout as String;
}

/// Plants a task from raw XML, so a state the COM builder cannot produce can
/// still be tested.
///
/// `schtasks /create /xml` is the only way to register a task with a *disabled*
/// trigger, or with no trigger at all — the states a user reaches from the Task
/// Scheduler UI and this package must read correctly.
void plantTaskXml(String innerXml) {
  final directory = Directory.systemTemp.createTempSync('ja_xml');
  addTearDown(() => directory.deleteSync(recursive: true));
  final file = File('${directory.path}${Platform.pathSeparator}task.xml');
  file.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
$innerXml
</Task>
''', encoding: utf8);

  final result = Process.runSync('schtasks', [
    '/create',
    '/tn',
    _fullTaskName(),
    '/xml',
    file.path,
    '/f',
  ]);
  expect(
    result.exitCode,
    0,
    reason: 'schtasks should have planted the task: ${result.stderr}',
  );
}

String _execActions() =>
    '''
  <Actions Context="Author">
    <Exec><Command>$_realExecutable</Command></Exec>
  </Actions>
''';

// The **third store**, and the one this backend originally missed. The Task
// Scheduler UI can switch off the *task* and it can switch off a *trigger*, and
// they are different commands that do not touch each other. A task whose logon
// trigger is disabled — or which has no trigger, or only a trigger of another
// type — is registered, enabled, and will never start at login.
//
// Every state below is reachable from that UI, and in every one of them
// `isEnabled()` used to report `true` for a program that could not run.
void _triggerStoreTests() {
  group('isEnabled reads the trigger, not only the task', () {
    test('is false when the logon trigger is disabled', () async {
      plantTaskXml('''
  <Triggers>
    <LogonTrigger><Enabled>false</Enabled><UserId>${currentUserSid()}</UserId></LogonTrigger>
  </Triggers>
${_execActions()}''');

      expect(await _backend().isEnabled(), isFalse);
    });

    test('is false when the task carries no trigger at all', () async {
      plantTaskXml('  <Triggers />\n${_execActions()}');

      expect(await _backend().isEnabled(), isFalse);
    });

    test('is false when the only trigger is not a logon trigger', () async {
      plantTaskXml('''
  <Triggers>
    <TimeTrigger><StartBoundary>2099-01-01T00:00:00</StartBoundary></TimeTrigger>
  </Triggers>
${_execActions()}''');

      expect(await _backend().isEnabled(), isFalse);
    });

    test('is true when an enabled logon trigger is present', () async {
      plantTaskXml('''
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>${currentUserSid()}</UserId></LogonTrigger>
  </Triggers>
${_execActions()}''');

      expect(await _backend().isEnabled(), isTrue);
    });

    // A disabled trigger is still ours, so it is still ours to remove.
    test('disable removes a task whose trigger is off', () async {
      plantTaskXml('''
  <Triggers>
    <LogonTrigger><Enabled>false</Enabled><UserId>${currentUserSid()}</UserId></LogonTrigger>
  </Triggers>
${_execActions()}''');

      await _backend().disable();

      expect(schtasksSees(), isFalse);
    });
  });

  // A task this package wrote always has exactly one action. One that begins
  // the same way but carries more is not ours, and deleting it would destroy
  // the extra actions with no undo.
  group('a task with more than one action', () {
    void plantTwoActions() {
      plantTaskXml('''
  <Triggers>
    <LogonTrigger><Enabled>true</Enabled><UserId>${currentUserSid()}</UserId></LogonTrigger>
  </Triggers>
  <Actions Context="Author">
    <Exec><Command>$_realExecutable</Command></Exec>
    <Exec><Command>${r'C:\Windows\System32\notepad.exe'}</Command></Exec>
  </Actions>
''');
    }

    test('is not reported as ours', () async {
      plantTwoActions();

      expect(await _backend().isEnabled(), isFalse);
    });

    test('is left in place by disable', () async {
      plantTwoActions();

      await _backend().disable();

      expect(schtasksSees(), isTrue);
    });
  });

  group('a task name Task Scheduler would read as a path', () {
    WindowsTaskSchedulerBackend nested() => WindowsTaskSchedulerBackend(
      config: AutostartConfig(
        appName: r'Sub\Nested',
        label: 'dev.justautostart.test',
        executablePath: _realExecutable,
      ),
      scheduler: _scheduler,
    );

    // Accepting it creates a subfolder that outlives `disable()` and then makes
    // `deleteFolder()` fail, so it is refused before anything is written.
    test('is refused rather than silently creating a folder', () {
      expect(nested().enable(), throwsArgumentError);
    });

    test('leaves nothing behind when refused', () async {
      await expectLater(nested().enable(), throwsArgumentError);

      expect(
        Process.runSync('schtasks', [
          '/query',
          '/tn',
          '${_scratchFolder.path}${Platform.pathSeparator}Sub',
        ]).exitCode,
        isNot(0),
      );
    });
  });
}
