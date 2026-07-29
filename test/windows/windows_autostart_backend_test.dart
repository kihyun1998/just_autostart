@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/windows/registry.dart';
import 'package:just_autostart/src/backends/windows/task_scheduler.dart';
import 'package:just_autostart/src/backends/windows/windows_autostart_backend.dart';
import 'package:just_autostart/src/backends/windows/windows_run_key_backend.dart';
import 'package:just_autostart/src/backends/windows/windows_task_scheduler_backend.dart';
import 'package:test/test.dart';

import 'startup_approval_fixtures.dart';

/// Both mechanisms, pointed at scratch locations, driven for real.
///
/// Nothing here is faked. The whole question this file answers is whether two
/// *independent* stores end up consistent, and a fake of either would answer it
/// about the fake.
const _runKeyPath = r'Software\just_autostart_test_migration\Run';
const _approvalPath = r'Software\just_autostart_test_migration\Approved';
const _runKey = RegistryLocation(path: _runKeyPath);
const _approvalKey = RegistryLocation(path: _approvalPath);
const _registry = WindowsRegistry();

const _taskFolder = TaskFolder(r'\just_autostart_test_migration');
const _scheduler = WindowsTaskScheduler(folder: _taskFolder);

const _appName = 'JustAutostartTest';

final _realExecutable = Platform.resolvedExecutable;

AutostartConfig _config({String? executablePath}) => AutostartConfig(
  appName: _appName,
  label: 'dev.justautostart.test',
  executablePath: executablePath ?? _realExecutable,
);

WindowsRunKeyBackend _runKeyBackend({String? executablePath}) =>
    WindowsRunKeyBackend(
      config: _config(executablePath: executablePath),
      runKey: _runKey,
      approvalKey: _approvalKey,
    );

WindowsTaskSchedulerBackend _taskBackend({String? executablePath}) =>
    WindowsTaskSchedulerBackend(
      config: _config(executablePath: executablePath),
      scheduler: _scheduler,
    );

/// The composite, configured for whichever mechanism the caller wants.
WindowsAutostartBackend _backend({
  required WindowsAutostartMechanism mechanism,
  String? executablePath,
}) {
  final runKey = _runKeyBackend(executablePath: executablePath);
  final task = _taskBackend(executablePath: executablePath);

  return mechanism == WindowsAutostartMechanism.runKey
      ? WindowsAutostartBackend(chosen: runKey, other: task)
      : WindowsAutostartBackend(chosen: task, other: runKey);
}

String? runKeyValue() => _registry.readString(_runKey, _appName);

Uint8List? approvalValue() => _registry.readBinary(_approvalKey, _appName);

bool taskExists() => _scheduler.readTask(_appName) != null;

/// Plants an entry in the `Run` key that this package did **not** write.
void plantForeignRunValue([
  String value = r'"C:\Program Files\OtherVendor\other.exe" /background',
]) {
  _registry.writeString(_runKey, _appName, value);
}

/// Plants a scheduled task that this package did **not** write.
void plantForeignTask() {
  final result = Process.runSync('schtasks', [
    '/create',
    '/tn',
    '${_taskFolder.path}\\$_appName',
    '/tr',
    r'C:\Windows\System32\notepad.exe',
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
/// **Not `schtasks /query /tn <folder>`**, which returns a non-zero exit code
/// for a folder that is absent *and* for one that is merely empty — so an
/// assertion built on it cannot fail for the case it exists to catch. Task
/// Scheduler stores folders as real directories under `System32\Tasks`, and
/// that is a reader outside this package.
bool taskFolderExists(String path) =>
    Directory('${r'C:\Windows\System32\Tasks'}$path').existsSync();

void main() {
  setUp(() {
    _registry
      ..deleteValue(_runKey, _appName)
      ..deleteValue(_approvalKey, _appName);
    _scheduler.deleteTask(_appName);
  });

  tearDownAll(() {
    _scheduler
      ..deleteTask(_appName)
      ..deleteFolder();
    Process.runSync('reg', [
      'delete',
      r'HKCU\Software\just_autostart_test_migration',
      '/f',
    ]);

    // Both scratch locations, asserted gone rather than assumed.
    expect(
      taskFolderExists(_taskFolder.path),
      isFalse,
      reason: 'the scratch task folder should be gone',
    );
    expect(
      Process.runSync('reg', [
        'query',
        r'HKCU\Software\just_autostart_test_migration',
      ]).exitCode,
      isNot(0),
      reason: 'the scratch registry tree should be gone',
    );
  });

  // The upgrade this ticket exists for: version 1 shipped through the `Run`
  // key, version 2 switches to Task Scheduler to be rid of the console window.
  // Without cleanup the user gets the program twice at every login — and the
  // console window still appears, which was the reason for switching.
  group('migrating from the Run key to Task Scheduler', () {
    test('leaves exactly one registration', () async {
      await _runKeyBackend().enable();
      expect(runKeyValue(), isNotNull);

      await _backend(
        mechanism: WindowsAutostartMechanism.taskScheduler,
      ).enable();

      expect(taskExists(), isTrue);
      expect(runKeyValue(), isNull, reason: 'the old registration must go');
    });

    // The `Run` key keeps the user's veto in a *second* value. Removing the
    // registration and leaving that behind would drop a stale entry in the
    // registry that nothing owns any more.
    test('removes the approval value too', () async {
      await _runKeyBackend().enable();
      expect(approvalValue(), isNotNull);

      await _backend(
        mechanism: WindowsAutostartMechanism.taskScheduler,
      ).enable();

      expect(approvalValue(), isNull);
    });

    test('removes a registration the user had vetoed', () async {
      await _runKeyBackend().enable();
      _registry.writeBinary(_approvalKey, _appName, realDisabledApproval());

      await _backend(
        mechanism: WindowsAutostartMechanism.taskScheduler,
      ).enable();

      expect(runKeyValue(), isNull);
      expect(approvalValue(), isNull);
      expect(taskExists(), isTrue);
    });
  });

  group('migrating from Task Scheduler to the Run key', () {
    test('leaves exactly one registration', () async {
      await _taskBackend().enable();
      expect(taskExists(), isTrue);

      await _backend(mechanism: WindowsAutostartMechanism.runKey).enable();

      expect(runKeyValue(), isNotNull);
      expect(taskExists(), isFalse, reason: 'the old task must go');
    });

    // The task folder is shared by every application using this package, so
    // removing our task must not remove the folder — another application's
    // task may be sitting in it.
    test('leaves the task folder in place', () async {
      await _taskBackend().enable();

      await _backend(mechanism: WindowsAutostartMechanism.runKey).enable();

      expect(
        taskFolderExists(_taskFolder.path),
        isTrue,
        reason: 'the folder is shared and is not this migration to remove',
      );
    });
  });

  // The sacred path, and it is worse here than in `disable()`: the caller asked
  // to *enable* something and a deletion happens as a side effect. They never
  // asked for a deletion at all.
  group('cleanup never touches what this package did not write', () {
    test('leaves a foreign Run key entry alone', () async {
      plantForeignRunValue();

      await _backend(
        mechanism: WindowsAutostartMechanism.taskScheduler,
      ).enable();

      expect(
        runKeyValue(),
        r'"C:\Program Files\OtherVendor\other.exe" /background',
      );
      expect(taskExists(), isTrue);
    });

    test('leaves a foreign scheduled task alone', () async {
      plantForeignTask();

      await _backend(mechanism: WindowsAutostartMechanism.runKey).enable();

      expect(taskExists(), isTrue);
      expect(
        _scheduler.readTask(_appName)!.executablePath!.toLowerCase(),
        contains('notepad.exe'),
      );
      expect(runKeyValue(), isNotNull);
    });

    // A `Run` value in the shape this package writes, but naming somebody
    // else's program. Recognising the *format* is not ownership — six of six
    // third-party entries on a real machine are in the same shape.
    test('leaves a well-formed foreign entry alone', () async {
      plantForeignRunValue(r'"C:\Windows\System32\notepad.exe"');

      await _backend(
        mechanism: WindowsAutostartMechanism.taskScheduler,
      ).enable();

      expect(runKeyValue(), r'"C:\Windows\System32\notepad.exe"');
    });

    // A registration this package wrote for an *earlier install path* is not
    // removed either — the guard is the path, and that is the safe direction to
    // fail. Recorded so the cost is visible rather than discovered.
    test('leaves behind a registration written at an older path', () async {
      await _runKeyBackend(
        executablePath: r'C:\Windows\System32\notepad.exe',
      ).enable();

      await _backend(
        mechanism: WindowsAutostartMechanism.taskScheduler,
      ).enable();

      expect(runKeyValue(), isNotNull);
    });
  });

  group('cleanup is silent when there is nothing to clean', () {
    test('enabling through the Run key on a fresh machine', () async {
      await expectLater(
        _backend(mechanism: WindowsAutostartMechanism.runKey).enable(),
        completes,
      );

      expect(runKeyValue(), isNotNull);
      expect(taskExists(), isFalse);
    });

    test('enabling through Task Scheduler on a fresh machine', () async {
      await expectLater(
        _backend(mechanism: WindowsAutostartMechanism.taskScheduler).enable(),
        completes,
      );

      expect(taskExists(), isTrue);
      expect(runKeyValue(), isNull);
    });

    test('is idempotent', () async {
      final backend = _backend(
        mechanism: WindowsAutostartMechanism.taskScheduler,
      );

      await backend.enable();
      await backend.enable();

      expect(taskExists(), isTrue);
      expect(runKeyValue(), isNull);
      expect(await backend.isEnabled(), isTrue);
    });
  });

  // "Off" has to mean off. A caller configured for Task Scheduler who switches
  // autostart off while a `Run` key entry from an earlier version is still
  // there would otherwise be told it is off while the program keeps launching.
  group('disable clears both mechanisms', () {
    test('removes a Run key registration while configured for tasks', () async {
      await _runKeyBackend().enable();
      await _taskBackend().enable();

      await _backend(
        mechanism: WindowsAutostartMechanism.taskScheduler,
      ).disable();

      expect(runKeyValue(), isNull);
      expect(approvalValue(), isNull);
      expect(taskExists(), isFalse);
    });

    test('removes a task while configured for the Run key', () async {
      await _runKeyBackend().enable();
      await _taskBackend().enable();

      await _backend(mechanism: WindowsAutostartMechanism.runKey).disable();

      expect(runKeyValue(), isNull);
      expect(taskExists(), isFalse);
    });

    test('leaves foreign entries in both stores alone', () async {
      plantForeignRunValue();
      plantForeignTask();

      await _backend(mechanism: WindowsAutostartMechanism.runKey).disable();

      expect(runKeyValue(), isNotNull);
      expect(taskExists(), isTrue);
    });

    test('is idempotent', () async {
      final backend = _backend(mechanism: WindowsAutostartMechanism.runKey);
      await backend.enable();

      await backend.disable();
      await backend.disable();

      expect(runKeyValue(), isNull);
      expect(taskExists(), isFalse);
    });

    test('does not error on a machine with nothing registered', () async {
      await expectLater(
        _backend(mechanism: WindowsAutostartMechanism.runKey).disable(),
        completes,
      );
    });
  });

  group('isEnabled reports the chosen mechanism', () {
    test('is true for the chosen mechanism only', () async {
      await _runKeyBackend().enable();

      expect(
        await _backend(mechanism: WindowsAutostartMechanism.runKey).isEnabled(),
        isTrue,
      );
      // The documented bound: a registration made by an earlier version through
      // the other mechanism reads as `false` until `enable()` or `disable()`
      // converges the two.
      expect(
        await _backend(
          mechanism: WindowsAutostartMechanism.taskScheduler,
        ).isEnabled(),
        isFalse,
      );
    });

    test('is true after migrating, through the new mechanism', () async {
      await _runKeyBackend().enable();

      final migrated = _backend(
        mechanism: WindowsAutostartMechanism.taskScheduler,
      );
      await migrated.enable();

      expect(await migrated.isEnabled(), isTrue);
    });
  });

  // A failure while cleaning up must reach the caller. A half-migrated machine
  // that nobody was told about is the state this class exists to prevent.
  group('a cleanup failure is reported', () {
    test('propagates rather than swallowing', () async {
      final backend = WindowsAutostartBackend(
        chosen: _runKeyBackend(),
        other: const _FailingBackend(),
      );

      // Its own type, and not the failure underneath. A caller that cannot
      // tell this apart from "enable failed" would reasonably not save the
      // user's preference and report autostart as off — while it is on.
      await expectLater(
        backend.enable(),
        throwsA(
          isA<MechanismCleanupException>()
              .having((e) => e.cause, 'cause', isA<AutostartOsException>())
              .having((e) => e.message, 'message', contains('twice')),
        ),
      );

      // The chosen mechanism is still registered: the caller is told the
      // cleanup failed, not that the whole operation did.
      expect(runKeyValue(), isNotNull);
    });

    // Stopping at the first failure would leave the other mechanism launching
    // the program while `disable()` had already reported an error the caller
    // may reasonably read as "nothing happened".
    test('disable clears the second store even when the first fails', () async {
      await _runKeyBackend().enable();
      expect(runKeyValue(), isNotNull);

      final backend = WindowsAutostartBackend(
        chosen: const _FailingBackend(),
        other: _runKeyBackend(),
      );

      await expectLater(
        backend.disable(),
        throwsA(isA<AutostartOsException>()),
      );

      expect(
        runKeyValue(),
        isNull,
        reason: 'the reachable store must still be cleared',
      );
    });

    test('disable clears the first store even when the second fails', () async {
      await _runKeyBackend().enable();

      final backend = WindowsAutostartBackend(
        chosen: _runKeyBackend(),
        other: const _FailingBackend(),
      );

      await expectLater(
        backend.disable(),
        throwsA(isA<AutostartOsException>()),
      );

      expect(runKeyValue(), isNull);
    });
  });

  // The Task Scheduler tree is machine-wide where `HKEY_CURRENT_USER` is not,
  // so two users of one shared installation have byte-identical executable
  // paths. Before this change a `Run` key caller never touched the task tree at
  // all; now its `enable()` does, uninvited — which is why the task guard
  // carries a term the `Run` key's does not: the principal must be this user.
  //
  // **The end-to-end case cannot be built here, and that is measured rather
  // than assumed.** An unelevated process cannot register a task for any
  // principal but itself: `schtasks /create /xml` naming `S-1-5-19` is refused
  // with access denied, and naming an unresolvable SID is refused with "no
  // mapping between account names and security IDs". Producing another user's
  // task needs a second account. So the guard is proved in two halves — the
  // identity comparison by `current_user_test.dart`, and the fact that the term
  // is load-bearing here.
  group('the principal is part of the ownership guard', () {
    test('a task this user registered reads as this user', () async {
      await _taskBackend().enable();

      expect(_scheduler.readTask(_appName)!.runsAsCurrentUser, isTrue);
    });

    // What this pins, checked by mutation: reading the **wrong property** for
    // the principal turns this package's own tasks into strangers, so the read
    // is live and correct.
    //
    // What it does **not** pin, also checked by mutation: deleting the term
    // altogether leaves every test in this repository green. The rejecting
    // branch needs a task belonging to somebody else, and an unelevated process
    // cannot make one. `current_user_test.dart` covers the comparison itself —
    // that is the half of this guard a single account can prove.
    test('a task read with the wrong property stops being ours', () async {
      await _taskBackend().enable();

      expect(await _taskBackend().isEnabled(), isTrue);

      await _backend(mechanism: WindowsAutostartMechanism.runKey).enable();
      expect(taskExists(), isFalse, reason: 'ours, so ours to clean up');
    });
  });
}

/// A backend whose cleanup always fails.
///
/// The only fake in this file, and it stands in for a condition no scratch
/// location can produce on demand — the Task Scheduler service being
/// unavailable, or a task whose security descriptor refuses deletion.
final class _FailingBackend implements AutostartBackend {
  const _FailingBackend();

  @override
  Future<void> enable() async => throw UnimplementedError();

  @override
  Future<void> disable() async => throw const AutostartOsException(
    operation: 'ITaskFolder::DeleteTask',
    detail: 'access denied',
    errorCode: 5,
  );

  @override
  Future<bool> isEnabled() async => throw UnimplementedError();
}
