@TestOn('windows')
library;

import 'dart:io';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/windows/current_user.dart';
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

/// Whether a task folder exists, regardless of whether it holds any tasks.
///
/// **Not `schtasks /query /tn <folder>`**, which exits non-zero for a folder
/// that is absent *and* for one that is merely empty — so an assertion built on
/// it passes for the leftover it exists to catch. Task Scheduler stores folders
/// as real directories under `System32\Tasks`.
bool taskFolderExists(String path) =>
    Directory('${r'C:\Windows\System32\Tasks'}$path').existsSync();

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
      taskFolderExists(_scratchFolder.path),
      isFalse,
      reason: 'the scratch task folder should be gone',
    );
  });

  group('createTask', () {
    test('registers a task Windows itself can see', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      expect(schtasksSees('Probe'), isTrue);
    });

    test('creates the folder when it is not there yet', () {
      _scheduler.deleteFolder();

      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      expect(schtasksSees('Probe'), isTrue);
    });

    test('records the executable as the task action', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

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
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      final xml = schtasksXml('Probe');
      expect(xml, contains('<LogonType>InteractiveToken</LogonType>'));
      expect(xml, isNot(contains('S-1-5-18')));
    });

    test('is idempotent', () {
      _scheduler
        ..createTask('Probe', TaskRegistration(executablePath: _realExecutable))
        ..createTask(
          'Probe',
          TaskRegistration(executablePath: _realExecutable),
        );

      expect(schtasksSees('Probe'), isTrue);
    });

    test('updates the action when the executable changes', () {
      _scheduler
        ..createTask('Probe', TaskRegistration(executablePath: _realExecutable))
        ..createTask(
          'Probe',
          const TaskRegistration(
            executablePath: r'C:\Windows\System32\cmd.exe',
          ),
        );

      expect(
        schtasksXml('Probe'),
        contains(r'<Command>C:\Windows\System32\cmd.exe</Command>'),
      );
    });

    test('gives the task a logon trigger', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      expect(schtasksXml('Probe'), contains('<LogonTrigger>'));
    });

    // A logon trigger with no `UserId` fires when *any* account logs on, and
    // the task then runs as its principal — so a second user signing in would
    // start the first user's program.
    //
    // The SID this package writes does **not** come back as a SID: Task
    // Scheduler normalises the trigger's `UserId` to `DOMAIN\Name`, while
    // leaving the principal's as the SID it was given. So the assertion is
    // against `whoami`, which reports the same normalised form — a different
    // tool answering the same question.
    test('confines the trigger to the user who registered it', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      final whoami = (Process.runSync('whoami', const []).stdout as String)
          .trim();
      final trigger = RegExp(
        r'<LogonTrigger>(.*?)</LogonTrigger>',
        dotAll: true,
      ).firstMatch(schtasksXml('Probe'))?.group(1);

      expect(trigger, isNotNull, reason: 'there should be a logon trigger');
      expect(
        trigger,
        contains('<UserId>'),
        reason:
            'a trigger with no UserId fires for every account on the machine',
      );
      expect(trigger!.toLowerCase(), contains(whoami.toLowerCase()));
    });

    // `LeastPrivilege` is the default, and **Task Scheduler omits defaults from
    // the XML** — so its absence here cannot distinguish "set to least
    // privilege" from "never set", and asserting on its presence would fail
    // against correct code. What the XML *can* show is the elevated value not
    // being there, which is the claim that matters: this package never asks for
    // elevation.
    test('never asks for an elevated run level', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      final xml = schtasksXml('Probe');
      expect(xml, contains('<LogonType>InteractiveToken</LogonType>'));
      expect(xml, isNot(contains('HighestAvailable')));

      // Anchored **inside** `<Principal>`. An unanchored search for the SID
      // matches the logon trigger's own `UserId` too, so it stays green even if
      // `IPrincipal::put_UserId` is never called — and Task Scheduler defaults
      // the principal to this user anyway, so the assertion could not tell
      // "written" from "defaulted" either. Both of those made a wrong slot
      // index on an FFI sacred path invisible.
      final principal = RegExp(
        r'<Principal\b[^>]*>(.*?)</Principal>',
        dotAll: true,
      ).firstMatch(xml)?.group(1);
      expect(principal, isNotNull);
      expect(principal, contains('<UserId>${currentUserSid()}</UserId>'));
    });

    // Every one of these defaults is wrong for a program that should start at
    // login and keep running, and none of them appear in the XML of a task
    // that has not overridden them — so an empty `<Settings>` is not an
    // absence, it is three traps. Measured on a fresh definition:
    // `ExecutionTimeLimit` is `PT72H`, which kills a daemon after three days.
    test('overrides the settings that would stop a daemon', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      final xml = schtasksXml('Probe');
      expect(xml, contains('<DisallowStartIfOnBatteries>false<'));
      expect(xml, contains('<StopIfGoingOnBatteries>false<'));
      expect(xml, contains('<StartWhenAvailable>true<'));
      expect(xml, contains('<ExecutionTimeLimit>PT0S<'));
    });

    test('hides the launched window by default', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      expect(schtasksXml('Probe'), contains('<HideAppWindow>true<'));
    });

    test('leaves the window alone when asked not to hide it', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable, hideWindow: false),
      );

      expect(schtasksXml('Probe'), isNot(contains('<HideAppWindow>true<')));
    });

    test('records the arguments alongside the path', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(
          executablePath: _realExecutable,
          args: const ['--daemon', r'--out=C:\My Docs'],
        ),
      );

      expect(
        schtasksXml('Probe'),
        contains(r'<Arguments>--daemon "--out=C:\My Docs"</Arguments>'),
      );
    });

    test('carries no delay when none was asked for', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      expect(schtasksXml('Probe'), isNot(contains('<Delay>')));
    });

    test('carries the configured delay', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(
          executablePath: _realExecutable,
          delay: const Duration(minutes: 2, seconds: 30),
        ),
      );

      expect(schtasksXml('Probe'), contains('<Delay>PT2M30S</Delay>'));
    });
  });

  group('readTask', () {
    test('is null for a task that was never registered', () {
      expect(_scheduler.readTask('NeverRegistered'), isNull);
    });

    test('is null when the folder does not exist', () {
      _scheduler.deleteFolder();

      expect(_scheduler.readTask('Probe'), isNull);
    });

    test('reads back the path and arguments it was given', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(
          executablePath: _realExecutable,
          args: const ['--daemon', r'--out=C:\My Docs'],
        ),
      );

      final task = _scheduler.readTask('Probe')!;
      expect(task.executablePath, _realExecutable);
      expect(task.args, ['--daemon', r'--out=C:\My Docs']);
    });

    test('reads back an empty argument list', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      expect(_scheduler.readTask('Probe')!.args, isEmpty);
    });

    test('reports a freshly registered task as enabled', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      expect(_scheduler.readTask('Probe')!.enabled, isTrue);
    });

    // The second store. A user switching a task off in the Task Scheduler UI
    // leaves the registration exactly as it was — the same shape as the `Run`
    // key's `StartupApproved` veto, which is why reading only "does it exist"
    // reports a program that will never run as enabled.
    test('reports a task the user switched off as disabled', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      final result = Process.runSync('schtasks', [
        '/change',
        '/tn',
        '${_scratchFolder.path}\\Probe',
        '/disable',
      ]);
      expect(result.exitCode, 0, reason: 'schtasks should have disabled it');

      final task = _scheduler.readTask('Probe')!;
      expect(task.enabled, isFalse);
      expect(
        task.executablePath,
        _realExecutable,
        reason: 'the registration itself is untouched — that is the point',
      );
    });

    // A task somebody else registered under a colliding name whose action is
    // an ordinary exec action. It reads back fine — the point is that the path
    // is *theirs*, which is what the ownership guard acts on.
    test('reads back a task somebody else registered', () {
      final result = Process.runSync('schtasks', [
        '/create',
        '/tn',
        '${_scratchFolder.path}\\Probe',
        '/tr',
        r'C:\Windows\System32\cmd.exe /c exit',
        '/sc',
        'ONCE',
        '/st',
        '23:59',
        '/f',
      ]);
      expect(result.exitCode, 0, reason: 'schtasks should have created it');

      final task = _scheduler.readTask('Probe')!;
      expect(task.executablePath!.toLowerCase(), contains('cmd.exe'));
      expect(task.startsAtLogon, isFalse, reason: 'it has a time trigger');
    });

    // An action that is *not* an executable action does not answer to
    // `IExecAction`, and that is the honest signal the task is not ours.
    // `schtasks` cannot plant one — `ShowMessage` and `SendEmail` were removed
    // in Windows 8 — so the XML form is used, with a `ComHandler`.
    test('reports no executable for a task with a non-exec action', () {
      final directory = Directory.systemTemp.createTempSync('ja_comhandler');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}${Platform.pathSeparator}task.xml');
      file.writeAsStringSync('''
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>${currentUserSid()}</UserId>
      <LogonType>InteractiveToken</LogonType>
    </Principal>
  </Principals>
  <Actions Context="Author">
    <ComHandler>
      <ClassId>{00000000-0000-0000-0000-000000000001}</ClassId>
    </ComHandler>
  </Actions>
</Task>
''');

      final result = Process.runSync('schtasks', [
        '/create',
        '/tn',
        '${_scratchFolder.path}\\Probe',
        '/xml',
        file.path,
        '/f',
      ]);
      expect(result.exitCode, 0, reason: 'schtasks said: ${result.stderr}');

      expect(_scheduler.readTask('Probe')!.executablePath, isNull);
    });
  });

  group('encodeTaskDuration', () {
    // `Delay` is a BSTR in ISO 8601 form, not a number of seconds. Zero is
    // `PT0S` and not the empty string, which would mean "no delay set" — a
    // different state from "a delay of nothing", and the one this package uses
    // to mean "no execution time limit".
    test('spells zero as PT0S', () {
      expect(encodeTaskDuration(Duration.zero), 'PT0S');
    });

    for (final (duration, expected) in const <(Duration, String)>[
      (Duration(seconds: 30), 'PT30S'),
      (Duration(minutes: 5), 'PT5M'),
      (Duration(hours: 2), 'PT2H'),
      (Duration(minutes: 2, seconds: 30), 'PT2M30S'),
      (Duration(hours: 1, minutes: 30, seconds: 15), 'PT1H30M15S'),
      (Duration(hours: 26), 'PT26H'),
      (Duration(seconds: 60), 'PT1M'),
      (Duration(seconds: 3600), 'PT1H'),
    ]) {
      test('encodes $duration as $expected', () {
        expect(encodeTaskDuration(duration), expected);
      });
    }

    test('refuses a negative duration rather than writing a positive one', () {
      expect(
        () => encodeTaskDuration(const Duration(seconds: -1)),
        throwsArgumentError,
      );
    });

    // The trap this guard exists for. A sub-second duration is neither negative
    // nor zero, and truncating hours, minutes and seconds all to zero used to
    // leave the bare string `"PT"` — which `put_Delay` accepts in silence and
    // `RegisterTaskDefinition` then rejects with an error that never mentions
    // the delay.
    for (final tiny in const [
      Duration(milliseconds: 500),
      Duration(milliseconds: 999),
      Duration(microseconds: 1),
    ]) {
      test('refuses $tiny rather than emitting "PT"', () {
        expect(() => encodeTaskDuration(tiny), throwsArgumentError);
      });
    }
  });

  group('deleteTask', () {
    test('removes a task Windows can no longer see', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      expect(_scheduler.deleteTask('Probe'), isTrue);
      expect(schtasksSees('Probe'), isFalse);
      expect(_scheduler.readTask('Probe'), isNull);
    });

    test('reports a task that was not there rather than throwing', () {
      expect(_scheduler.deleteTask('NeverRegistered'), isFalse);
    });

    test('is idempotent', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

      expect(_scheduler.deleteTask('Probe'), isTrue);
      expect(_scheduler.deleteTask('Probe'), isFalse);
    });

    test('reports false when the folder does not exist', () {
      _scheduler.deleteFolder();

      expect(_scheduler.deleteTask('Probe'), isFalse);
    });
  });

  // The guarded delete.
  //
  // **What this group cannot prove, stated up front.** The reason `deleteTaskIf`
  // exists is that the decision and the removal happen without letting go of the
  // connection. Replacing its body with the old two-session shape —
  // `readTask(name)`, then `deleteTask(name)` — passes **every test in this
  // repository**, checked by planting exactly that. The difference is the *size*
  // of the window between the guard and the delete, which is a timing property;
  // no functional assertion can see it, and a timing assertion on a shared CI
  // machine is a flake rather than a test. It is proved by the measurement
  // recorded in issue #16 and by reading the two implementations.
  //
  // What these tests *do* pin is the guard's behaviour, and that half is well
  // covered: ignoring the predicate's answer breaks tests in three files, most
  // of which predate this change. The raw failure count was **nine** and the
  // honest number is **seven** — `windows_autostart_backend_test.dart` carries
  // five of its groups twice, byte for byte, so two of the nine were the same
  // two assertions counted again. Recorded rather than quietly corrected,
  // because a coverage number obtained by counting failures is only as good as
  // the assumption that the failures are distinct.
  //
  // So: the dangerous half is covered seven times over, and the fast half is
  // not covered at all.
  //
  // So the cases below are the ones that are actually reachable — when the
  // predicate runs, what survives when it says no, and what the apartment looks
  // like afterwards.
  group('deleteTaskIf', () {
    void createProbe() => _scheduler.createTask(
      'Probe',
      TaskRegistration(executablePath: _realExecutable),
    );

    test('removes the task when the predicate accepts', () {
      createProbe();

      // The count belongs on **this** path, not only on the rejecting one. A
      // plausible wrong implementation re-reads and asks again after the
      // predicate accepts — "double-checking to shrink the window" — which
      // looks like more of what this change is for and is a second full read.
      // Counting only where the predicate says no would never see it.
      var calls = 0;
      final removed = _scheduler.deleteTaskIf('Probe', (_) {
        calls++;
        return true;
      });

      expect(removed, isTrue);
      expect(calls, 1);
      expect(
        schtasksSees('Probe'),
        isFalse,
        reason: 'Windows itself should no longer see it',
      );
    });

    test('leaves the task alone when the predicate rejects', () {
      createProbe();

      expect(_scheduler.deleteTaskIf('Probe', (_) => false), isFalse);
      expect(
        schtasksSees('Probe'),
        isTrue,
        reason: 'a rejected task must survive — this is the whole guard',
      );
    });

    // The side condition, not the return value: a name nothing registered must
    // not reach the predicate at all. A predicate invoked with a fabricated
    // record would be deciding about a task that is not there.
    test('never consults the predicate for a task that is absent', () {
      var calls = 0;
      final removed = _scheduler.deleteTaskIf('NeverRegistered', (_) {
        calls++;
        return true;
      });

      expect(removed, isFalse);
      expect(calls, 0);
    });

    test('never consults the predicate when the folder is absent', () {
      _scheduler.deleteFolder();

      var calls = 0;
      final removed = _scheduler.deleteTaskIf('Probe', (_) {
        calls++;
        return true;
      });

      expect(removed, isFalse);
      expect(calls, 0);
    });

    // The predicate has to see the same thing `readTask` would hand back, or
    // the backend's ownership rule is being applied to a different object than
    // the one it was written against.
    test('hands the predicate what readTask would have returned', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(
          executablePath: _realExecutable,
          args: const ['--daemon', r'--out=C:\My Docs'],
        ),
      );
      final expected = _scheduler.readTask('Probe')!;

      RegisteredTask? seen;
      var calls = 0;
      _scheduler.deleteTaskIf('Probe', (task) {
        calls++;
        seen = task;
        return false;
      });

      // Exactly once, not merely at least once: a second consultation would
      // mean a second read, which is the round trip this whole change removes.
      expect(calls, 1);
      expect(seen, isNotNull);
      expect(seen!.executablePath, expected.executablePath);
      expect(seen!.args, expected.args);
      expect(seen!.enabled, expected.enabled);
      expect(seen!.startsAtLogon, expected.startsAtLogon);
      expect(seen!.runsAsCurrentUser, expected.runsAsCurrentUser);
    });

    // A throw from the predicate has to cancel the deletion, and it has to
    // leave the thread usable.
    //
    // **What the follow-up call does and does not prove.** It proves the
    // deletion was cancelled and that the scheduler still works. It does *not*
    // prove `CoUninitialize` ran: if it had been skipped, the thread's COM
    // reference count would stay up, the next `CoInitializeEx` would return
    // `S_FALSE`, and `succeeded()` accepts that — so the follow-up would pass
    // either way. A leaked arena has no functional symptom at all. Both are
    // proved by reading `withCom`'s and `Arena`'s `finally` blocks, not here;
    // saying so is the point, because an assertion that cannot fail for the
    // thing its `reason:` names is this repo's most repeated defect.
    test(
      'a throwing predicate deletes nothing and leaves the scheduler usable',
      () {
        createProbe();

        expect(
          () => _scheduler.deleteTaskIf('Probe', (_) => throw StateError('no')),
          throwsStateError,
        );
        expect(
          schtasksSees('Probe'),
          isTrue,
          reason: 'the deletion must not have happened',
        );

        expect(_scheduler.readTask('Probe'), isNotNull);
        expect(_scheduler.deleteTaskIf('Probe', (_) => true), isTrue);
      },
    );
  });

  group('deleteFolder', () {
    test('removes a folder this package created', () {
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );
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
      _scheduler.createTask(
        'Probe',
        TaskRegistration(executablePath: _realExecutable),
      );

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
      expect(nested.readTask('Probe'), isNull);
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
        () => _scheduler.createTask(
          'bad<name>',
          TaskRegistration(executablePath: _realExecutable),
        ),
        throwsA(
          isA<AutostartOsException>()
              .having((e) => e.errorCode, 'errorCode', isNotNull)
              .having((e) => e.operation, 'operation', isNotEmpty),
        ),
      );
    });
  });
}
