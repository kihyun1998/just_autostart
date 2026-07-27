@TestOn('windows')
library;

import 'dart:io';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/windows/task_scheduler.dart';
import 'package:test/test.dart';

/// A folder of this package's own, well away from `\` and from anything
/// Windows ships. Every task these tests create lives here and teardown removes
/// the folder itself.
const _scratchFolder = TaskFolder(r'\just_autostart_test_scheduler');

const _scheduler = WindowsTaskScheduler(folder: _scratchFolder);

/// A path that certainly exists — a task with an action pointing nowhere is
/// still registerable, but there is no reason to test against a fiction.
final _realExecutable = Platform.resolvedExecutable;

/// Asks Windows' own tool whether a task is there.
///
/// Our writer agreeing with our reader would prove nothing about whether Task
/// Scheduler accepted what we registered, so every registration is confirmed by
/// something that is not us.
ProcessResult schtasksQuery(String name, {bool asXml = false}) {
  return Process.runSync('schtasks', [
    '/query',
    '/tn',
    '${_scratchFolder.path}\\$name',
    if (asXml) ...['/xml', 'ONE'],
  ]);
}

bool schtasksSees(String name) => schtasksQuery(name).exitCode == 0;

/// The registered task as Task Scheduler itself serialises it.
///
/// The `/v /fo LIST` listing would be easier to read and is **localised** — its
/// field names and values come out in the machine's display language, so an
/// assertion against it passes on an English CI runner and fails on a Korean
/// desktop. The XML is the same on every machine.
String schtasksXml(String name) {
  final result = schtasksQuery(name, asXml: true);
  expect(result.exitCode, 0, reason: 'schtasks should have found $name');
  return result.stdout as String;
}

void main() {
  setUp(() {
    _scheduler.deleteTask('Probe');
  });

  tearDownAll(() {
    _scheduler
      ..deleteTask('Probe')
      ..deleteFolder();

    // The folder is the one artifact these tests leave outside their own
    // control, so its removal is asserted rather than assumed.
    expect(
      Process.runSync('schtasks', [
        '/query',
        '/tn',
        _scratchFolder.path,
      ]).exitCode,
      isNot(0),
      reason: 'the scratch task folder should be gone',
    );
  });

  group('createTask', () {
    test('registers a task Windows itself can see', () {
      _scheduler.createTask('Probe', executablePath: _realExecutable);

      expect(schtasksSees('Probe'), isTrue);
    });

    test('creates the folder when it is not there yet', () {
      _scheduler.deleteFolder();

      _scheduler.createTask('Probe', executablePath: _realExecutable);

      expect(schtasksSees('Probe'), isTrue);
    });

    test('records the executable as the task action', () {
      _scheduler.createTask('Probe', executablePath: _realExecutable);

      expect(
        schtasksXml('Probe'),
        contains('<Command>$_realExecutable</Command>'),
      );
    });

    // This package never needs elevation, and the registration must therefore
    // run as whoever called it rather than as SYSTEM — `S-1-5-18`, the
    // well-known SID a machine-wide registration would carry.
    //
    // The elevation state of the machine is deliberately *not* asserted. CI
    // runners are elevated, so a test that only passed unprivileged would pass
    // there for the wrong reason.
    //
    // Nor does this pin `TASK_LOGON_INTERACTIVE_TOKEN` itself, and it should
    // not be read as doing so: with an empty `userId`, Task Scheduler
    // normalises `TASK_LOGON_NONE` to `InteractiveToken` too, so registering
    // with either constant produces byte-identical XML. What is asserted is the
    // outcome that matters — the task runs as this user — not the constant that
    // happens to produce it.
    test('registers the task to run as the current user', () {
      _scheduler.createTask('Probe', executablePath: _realExecutable);

      final xml = schtasksXml('Probe');
      expect(xml, contains('<LogonType>InteractiveToken</LogonType>'));
      expect(xml, isNot(contains('S-1-5-18')));
    });

    test('is idempotent', () {
      _scheduler
        ..createTask('Probe', executablePath: _realExecutable)
        ..createTask('Probe', executablePath: _realExecutable);

      expect(schtasksSees('Probe'), isTrue);
    });

    test('updates the action when the executable changes', () {
      _scheduler
        ..createTask('Probe', executablePath: _realExecutable)
        ..createTask('Probe', executablePath: r'C:\Windows\System32\cmd.exe');

      expect(
        schtasksXml('Probe'),
        contains(r'<Command>C:\Windows\System32\cmd.exe</Command>'),
      );
    });

    // A task with no trigger is registered and inert. That is what makes this
    // ticket provable on a real machine without anything ever launching, and
    // it is the line between this ticket and the one that adds the logon
    // trigger.
    test('leaves the task without a trigger', () {
      _scheduler.createTask('Probe', executablePath: _realExecutable);

      expect(schtasksXml('Probe'), contains('<Triggers />'));
    });
  });

  group('taskExists', () {
    test('is true for a task that was registered', () {
      _scheduler.createTask('Probe', executablePath: _realExecutable);

      expect(_scheduler.taskExists('Probe'), isTrue);
    });

    test('is false for a task that was never registered', () {
      expect(_scheduler.taskExists('NeverRegistered'), isFalse);
    });

    // A missing folder is the state a fresh machine is in. It must read as
    // "no task", not as a failure — `isEnabled()` is documented as answering a
    // question, not raising.
    test('is false when the folder itself does not exist', () {
      _scheduler.deleteFolder();

      expect(_scheduler.taskExists('Probe'), isFalse);
    });
  });

  group('deleteTask', () {
    test('removes a task Windows can no longer see', () {
      _scheduler.createTask('Probe', executablePath: _realExecutable);

      expect(_scheduler.deleteTask('Probe'), isTrue);
      expect(schtasksSees('Probe'), isFalse);
      expect(_scheduler.taskExists('Probe'), isFalse);
    });

    test('reports a task that was not there rather than throwing', () {
      expect(_scheduler.deleteTask('NeverRegistered'), isFalse);
    });

    test('is idempotent', () {
      _scheduler.createTask('Probe', executablePath: _realExecutable);

      expect(_scheduler.deleteTask('Probe'), isTrue);
      expect(_scheduler.deleteTask('Probe'), isFalse);
    });

    test('reports false when the folder does not exist', () {
      _scheduler.deleteFolder();

      expect(_scheduler.deleteTask('Probe'), isFalse);
    });
  });

  group('deleteFolder', () {
    test('removes a folder this package created', () {
      _scheduler.createTask('Probe', executablePath: _realExecutable);
      _scheduler.deleteTask('Probe');

      expect(_scheduler.deleteFolder(), isTrue);
      expect(
        Process.runSync('schtasks', [
          '/query',
          '/tn',
          _scratchFolder.path,
        ]).exitCode,
        isNot(0),
      );
    });

    test('reports a folder that was not there rather than throwing', () {
      _scheduler.deleteFolder();

      expect(_scheduler.deleteFolder(), isFalse);
    });

    // Refusing to empty a folder that still holds tasks is Task Scheduler's
    // own rule, and it is the right one to surface: a folder shared with
    // anything else must not be emptied by this package.
    test('refuses to remove a folder that still holds a task', () {
      _scheduler.createTask('Probe', executablePath: _realExecutable);

      expect(
        () => _scheduler.deleteFolder(),
        throwsA(isA<AutostartOsException>()),
      );
      expect(schtasksSees('Probe'), isTrue);
    });
  });

  // The folder is handed to `ITaskFolder::DeleteFolder` on the **root**, so a
  // path that degenerates to the empty string there names the root itself —
  // which holds every scheduled task Windows and every other application have
  // registered. This is the deletion sacred path, and it has no undo.
  group('TaskFolder', () {
    test('strips the leading separator for the COM call', () {
      expect(
        const TaskFolder(r'\just_autostart').relativePath,
        'just_autostart',
      );
    });

    test('keeps a nested path intact below the root', () {
      expect(const TaskFolder(r'\a\b').relativePath, r'a\b');
    });

    for (final rejected in const ['', 'no-separator', r'\trailing\']) {
      test('refuses "$rejected"', () {
        expect(() => TaskFolder(rejected).relativePath, throwsArgumentError);
      });
    }

    // The root is refused twice over, and which refusal arrives depends on the
    // build. A `const TaskFolder(r'\')` fails to compile; a runtime one trips
    // the constructor's assert in a debug build, and in a release build — where
    // asserts are gone — `relativePath` refuses it instead. The test names both
    // rather than pretending only one exists.
    test(r'refuses the root', () {
      expect(
        () => TaskFolder(r'\').relativePath,
        throwsA(anyOf(isArgumentError, isA<AssertionError>())),
      );
    });

    test('compares by path', () {
      expect(const TaskFolder(r'\a'), const TaskFolder(r'\a'));
      expect(
        const TaskFolder(r'\a').hashCode,
        const TaskFolder(r'\a').hashCode,
      );
      expect(const TaskFolder(r'\a'), isNot(const TaskFolder(r'\b')));
    });

    test('names its path when printed', () {
      expect(const TaskFolder(r'\a').toString(), r'TaskFolder(\a)');
    });
  });

  // Task Scheduler reports a missing *intermediate* folder with
  // `ERROR_PATH_NOT_FOUND` rather than `ERROR_FILE_NOT_FOUND`. Checking only
  // the latter turns a nested folder that is simply absent — the state of every
  // machine this has never run on — into a thrown failure out of the two
  // methods documented as answering a question.
  group('a nested folder that does not exist', () {
    const nested = WindowsTaskScheduler(
      folder: TaskFolder(r'\just_autostart_test_scheduler_absent\below'),
    );

    test('reads as no task rather than throwing', () {
      expect(nested.taskExists('Probe'), isFalse);
    });

    test('deletes as nothing rather than throwing', () {
      expect(nested.deleteTask('Probe'), isFalse);
    });

    test('reports no folder rather than throwing', () {
      expect(nested.deleteFolder(), isFalse);
    });
  });

  group('failures', () {
    // Task names may not contain path separators — Task Scheduler treats them
    // as folder structure. The failure has to arrive as this package's typed
    // exception carrying the numeric code, not as a raw HRESULT or a crash.
    test('surfaces a rejected task name as the shared typed exception', () {
      expect(
        () =>
            _scheduler.createTask('bad<name>', executablePath: _realExecutable),
        throwsA(
          isA<AutostartOsException>()
              .having((e) => e.errorCode, 'errorCode', isNotNull)
              .having((e) => e.operation, 'operation', isNotEmpty),
        ),
      );
    });
  });
}
