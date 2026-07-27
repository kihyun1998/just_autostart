@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/windows/registry.dart';
import 'package:just_autostart/src/backends/windows/windows_run_key_backend.dart';
import 'package:test/test.dart';

import 'startup_approval_fixtures.dart';

const _scratchPath = r'Software\just_autostart_test_backend\Run';
const _approvalPath = r'Software\just_autostart_test_backend\Approved';
const _scratchKey = RegistryLocation(path: _scratchPath);
const _approvalScratchKey = RegistryLocation(path: _approvalPath);
const _registry = WindowsRegistry();

/// A path that certainly exists, so `enable()` gets past its existence check.
final _realExecutable = Platform.resolvedExecutable;

AutostartConfig _config({
  String? executablePath,
  List<String> args = const [],
}) {
  return AutostartConfig(
    appName: 'JustAutostartTest',
    label: 'dev.justautostart.test',
    executablePath: executablePath ?? _realExecutable,
    args: args,
  );
}

WindowsRunKeyBackend _backend({
  String? executablePath,
  List<String> args = const [],
}) {
  return WindowsRunKeyBackend(
    config: _config(executablePath: executablePath, args: args),
    runKey: _scratchKey,
    approvalKey: _approvalScratchKey,
  );
}

String? rawStoredValue() =>
    _registry.readString(_scratchKey, 'JustAutostartTest');

Uint8List? rawApprovalValue() =>
    _registry.readBinary(_approvalScratchKey, 'JustAutostartTest');

/// Plants the value Windows writes when a user switches the entry off in Task
/// Manager: an odd first byte, then the FILETIME of the moment they did it.
void plantUserVeto() {
  _registry.writeBinary(
    _approvalScratchKey,
    'JustAutostartTest',
    realDisabledApproval(),
  );
}

void main() {
  setUp(() {
    _registry
      ..deleteValue(_scratchKey, 'JustAutostartTest')
      ..deleteValue(_approvalScratchKey, 'JustAutostartTest');
  });

  tearDownAll(() {
    Process.runSync('reg', [
      'delete',
      r'HKCU\Software\just_autostart_test_backend',
      '/f',
    ]);
  });

  group('enable', () {
    test('registers the executable so isEnabled reports it', () async {
      final backend = _backend();

      await backend.enable();

      expect(await backend.isEnabled(), isTrue);
    });

    test('stores the path quoted, even without spaces in it', () async {
      await _backend(executablePath: _realExecutable).enable();

      expect(rawStoredValue(), startsWith('"'));
      expect(rawStoredValue(), '"$_realExecutable"');
    });

    test('stores arguments after the quoted path', () async {
      await _backend(args: const ['--daemon', '-v']).enable();

      expect(rawStoredValue(), '"$_realExecutable" --daemon -v');
    });

    test('is idempotent', () async {
      final backend = _backend();

      await backend.enable();
      await backend.enable();

      expect(await backend.isEnabled(), isTrue);
      expect(rawStoredValue(), '"$_realExecutable"');
    });

    test('rejects an executable that does not exist', () {
      final backend = _backend(executablePath: r'C:\nope\missing.exe');

      expect(
        backend.enable(),
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

      expect(rawStoredValue(), isNull);
      expect(rawApprovalValue(), isNull);
    });
  });

  group('isEnabled', () {
    test('is false when nothing is registered', () async {
      expect(await _backend().isEnabled(), isFalse);
    });

    test('is false when the registration points elsewhere', () async {
      await _backend().enable();

      final moved = _backend(executablePath: r'C:\somewhere\else.exe');
      expect(await moved.isEnabled(), isFalse);
    });

    test('is false when the arguments differ', () async {
      await _backend(args: const ['--daemon']).enable();

      expect(await _backend(args: const ['--other']).isEnabled(), isFalse);
      expect(await _backend().isEnabled(), isFalse);
    });

    // Windows paths are case-insensitive, so a registration that differs only
    // in case launches the same file and must not be reported as off.
    test('is true when the path differs only in case', () async {
      await _backend().enable();

      final recased = _backend(executablePath: _realExecutable.toUpperCase());
      expect(await recased.isEnabled(), isTrue);
    });

    test('is false for a value this package did not write', () async {
      _registry.writeString(
        _scratchKey,
        'JustAutostartTest',
        '$_realExecutable --daemon', // unquoted: not our canonical form
      );

      expect(await _backend(args: const ['--daemon']).isEnabled(), isFalse);
    });
  });

  group('disable', () {
    test('removes a registration this package wrote', () async {
      final backend = _backend();
      await backend.enable();

      await backend.disable();

      expect(await backend.isEnabled(), isFalse);
      expect(rawStoredValue(), isNull);
    });

    test('is idempotent', () async {
      final backend = _backend();
      await backend.enable();

      await backend.disable();
      await backend.disable();

      expect(rawStoredValue(), isNull);
    });

    test('does not error when nothing is registered', () async {
      await expectLater(_backend().disable(), completes);
    });

    // The sacred path. The Run key is a shared namespace and the value name
    // comes from caller-supplied text, so a name collision must never cost a
    // third party their autostart.
    //
    // These entries are in the *well-formed* shape a real vendor writes —
    // quoted path, ordinary flags. An earlier version of this guard only
    // checked that the value parsed, which every one of the six third-party
    // entries on a real machine also does; it protected exactly the installers
    // that had done the wrong thing.
    test('leaves a well-formed third-party entry in place', () async {
      const foreign = r'"C:\Program Files\OtherVendor\other.exe" /background';
      _registry.writeString(_scratchKey, 'JustAutostartTest', foreign);

      await _backend().disable();

      expect(rawStoredValue(), foreign);
    });

    test('leaves a third-party entry with no arguments in place', () async {
      const foreign = r'"C:\Program Files\OtherVendor\other.exe"';
      _registry.writeString(_scratchKey, 'JustAutostartTest', foreign);

      await _backend().disable();

      expect(rawStoredValue(), foreign);
    });

    test('leaves an unparseable value in place', () async {
      final foreign = _realExecutable; // unquoted: not written by us
      _registry.writeString(_scratchKey, 'JustAutostartTest', foreign);

      await _backend().disable();

      expect(rawStoredValue(), foreign);
    });

    test('leaves a non-string value in place', () async {
      Process.runSync('reg', [
        'add',
        r'HKCU\' + _scratchPath,
        '/v',
        'JustAutostartTest',
        '/t',
        'REG_DWORD',
        '/d',
        '1',
        '/f',
      ]);

      await expectLater(_backend().disable(), completes);

      final probe = Process.runSync('reg', [
        'query',
        r'HKCU\' + _scratchPath,
        '/v',
        'JustAutostartTest',
      ]);
      expect(probe.exitCode, 0, reason: 'the foreign value must survive');
    });

    // Ours by path, so ours to remove even though the arguments have changed —
    // an application may pass different flags than the version that registered.
    test('removes our registration when only the arguments differ', () async {
      await _backend(args: const ['--old-flag']).enable();

      await _backend(args: const ['--new-flag']).disable();

      expect(rawStoredValue(), isNull);
    });

    // The cost of identifying entries by path: a registration left by an
    // earlier install at a different location is not cleaned up here. Safe
    // direction — `enable()` overwrites it, and one stale entry beats deleting
    // a third party's autostart.
    test('leaves behind a registration written at an older path', () async {
      _registry.writeString(
        _scratchKey,
        'JustAutostartTest',
        r'"C:\old\location\app.exe" --daemon',
      );

      await _backend().disable();

      expect(rawStoredValue(), r'"C:\old\location\app.exe" --daemon');
    });
  });

  group("the user's Task Manager toggle", () {
    test('isEnabled is true when no approval value exists', () async {
      // Windows writes nothing here until the toggle is first touched, so a
      // freshly registered entry has no approval value and is still enabled.
      _registry.writeString(
        _scratchKey,
        'JustAutostartTest',
        '"$_realExecutable"',
      );

      expect(rawApprovalValue(), isNull);
      expect(await _backend().isEnabled(), isTrue);
    });

    test('isEnabled is false once the user has switched it off', () async {
      await _backend().enable();
      plantUserVeto();

      expect(await _backend().isEnabled(), isFalse);
    });

    // The registration is untouched — the entry is still "registered", it just
    // will not run. Reporting on the registration alone is the lie this ticket
    // exists to remove.
    test('a veto does not disturb the registration itself', () async {
      await _backend().enable();
      plantUserVeto();

      expect(rawStoredValue(), '"$_realExecutable"');
      expect(await _backend().isEnabled(), isFalse);
    });

    test('enable writes the approval value Windows itself writes', () async {
      await _backend().enable();

      expect(
        rawApprovalValue(),
        Uint8List.fromList([2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
      );
    });

    test('enable stores it as REG_BINARY', () async {
      await _backend().enable();

      final probe = Process.runSync('reg', [
        'query',
        r'HKCU\' + _approvalPath,
        '/v',
        'JustAutostartTest',
      ]);
      expect(probe.exitCode, 0);
      expect(probe.stdout as String, contains('REG_BINARY'));
    });

    // The pinned product decision: `enable()` overrides the user's veto, the
    // same way `launch_at_startup` does. The calling application is expected to
    // have asked its user first.
    test('enable clears a veto the user had set', () async {
      plantUserVeto();

      await _backend().enable();

      expect(await _backend().isEnabled(), isTrue);
      expect(rawApprovalValue()!.first, 2);
    });

    test('disable removes both stores', () async {
      await _backend().enable();

      await _backend().disable();

      expect(rawStoredValue(), isNull);
      expect(rawApprovalValue(), isNull);
    });

    test('disable removes the approval value even after a veto', () async {
      await _backend().enable();
      plantUserVeto();

      await _backend().disable();

      expect(rawStoredValue(), isNull);
      expect(rawApprovalValue(), isNull);
    });

    // The sacred path reaches the approval store too: if the registration is
    // not ours, neither value is touched.
    test('disable leaves a third party approval value alone', () async {
      const foreign = r'"C:\Program Files\OtherVendor\other.exe" /background';
      _registry.writeString(_scratchKey, 'JustAutostartTest', foreign);
      plantUserVeto();

      await _backend().disable();

      expect(rawStoredValue(), foreign);
      expect(rawApprovalValue(), isNotNull);
    });

    test('disable is idempotent across both stores', () async {
      await _backend().enable();

      await _backend().disable();
      await _backend().disable();

      expect(rawStoredValue(), isNull);
      expect(rawApprovalValue(), isNull);
    });

    test(
      'disable does not error when only the approval value is absent',
      () async {
        await _backend().enable();
        _registry.deleteValue(_approvalScratchKey, 'JustAutostartTest');

        await expectLater(_backend().disable(), completes);

        expect(rawStoredValue(), isNull);
      },
    );

    // An orphaned approval value — its registration already removed by an
    // uninstaller, another autostart manager, or a crash between this package's
    // own two deletes — is deliberately left alone. Under a name we do not
    // currently own it cannot be attributed: it might be this application's
    // leftover, or a third party's, and a third party's *is the user's veto of
    // that application*. Clearing it would silently re-enable something they
    // switched off. It is inert while no registration exists, and `enable()`
    // overwrites it.
    test('disable leaves an orphaned approval value alone', () async {
      await _backend().enable();
      _registry.deleteValue(_scratchKey, 'JustAutostartTest');

      await _backend().disable();

      expect(rawApprovalValue(), isNotNull);
    });

    test('enable repairs an orphaned approval value', () async {
      plantUserVeto();
      expect(rawStoredValue(), isNull);

      await _backend().enable();

      expect(rawApprovalValue()!.first, 2);
      expect(await _backend().isEnabled(), isTrue);
    });
  });
}
