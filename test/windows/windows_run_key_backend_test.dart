@TestOn('windows')
library;

import 'dart:io';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/windows/registry.dart';
import 'package:just_autostart/src/backends/windows/windows_run_key_backend.dart';
import 'package:test/test.dart';

const _scratchPath = r'Software\just_autostart_test_backend';
const _scratchKey = RegistryLocation(path: _scratchPath);
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
  );
}

String? rawStoredValue() =>
    _registry.readString(_scratchKey, 'JustAutostartTest');

void main() {
  setUp(() {
    _registry.deleteValue(_scratchKey, 'JustAutostartTest');
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
}
