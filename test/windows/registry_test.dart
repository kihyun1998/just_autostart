@TestOn('windows')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/windows/registry.dart';
import 'package:test/test.dart';

import 'startup_approval_fixtures.dart';

/// A throwaway subkey under the current user. Nothing here touches the real
/// `Run` key, and teardown removes the whole tree.
const _scratchPath = r'Software\just_autostart_test_registry';

const _registry = WindowsRegistry();
const _location = RegistryLocation(path: _scratchPath);

/// Reads a value back with Windows' own tool.
///
/// Our writer agreeing with our reader would prove nothing about whether
/// Windows accepted what we wrote, so every write is confirmed by something
/// that is not us.
String? regQuery(String name) {
  final result = Process.runSync('reg', [
    'query',
    r'HKCU\' + _scratchPath,
    '/v',
    name,
  ]);
  if (result.exitCode != 0) return null;
  final line = (result.stdout as String)
      .split('\n')
      .firstWhere((l) => l.contains(name), orElse: () => '');
  final match = RegExp(r'REG_(?:EXPAND_)?SZ\s+(.*)$').firstMatch(line.trim());
  return match?.group(1)?.trimRight();
}

void main() {
  tearDownAll(() {
    Process.runSync('reg', [
      'delete',
      r'HKCU\Software\just_autostart_test_registry',
      '/f',
    ]);
  });

  group('WindowsRegistry', () {
    test('writes a value Windows itself can read back', () {
      _registry.writeString(_location, 'basic', r'"C:\app.exe" --daemon');

      expect(regQuery('basic'), r'"C:\app.exe" --daemon');
    });

    test('reads back what it wrote', () {
      _registry.writeString(_location, 'roundtrip', r'"C:\app.exe"');

      expect(_registry.readString(_location, 'roundtrip'), r'"C:\app.exe"');
    });

    test('returns null for a value that does not exist', () {
      expect(_registry.readString(_location, 'nothing-here'), isNull);
    });

    test('returns null for a key that does not exist', () {
      const missing = RegistryLocation(
        path: r'Software\just_autostart_test\definitely-absent',
      );

      expect(_registry.readString(missing, 'anything'), isNull);
    });

    test('overwrites an existing value', () {
      _registry
        ..writeString(_location, 'overwrite', 'first')
        ..writeString(_location, 'overwrite', 'second');

      expect(_registry.readString(_location, 'overwrite'), 'second');
      expect(regQuery('overwrite'), 'second');
    });

    // The fast-path buffer is 256 bytes; anything past it exercises the
    // ERROR_MORE_DATA retry, which is where a size-negotiation mistake turns
    // into a truncated read rather than a failing call.
    test('reads a value larger than the fast-path buffer', () {
      final long = 'x' * 4000;
      _registry.writeString(_location, 'long', long);

      expect(_registry.readString(_location, 'long'), long);
      expect(_registry.readString(_location, 'long')!.length, 4000);
    });

    test('round-trips a value at exactly the fast-path boundary', () {
      // 127 code units + terminator = 256 bytes.
      final exact = 'y' * 127;
      _registry.writeString(_location, 'exact', exact);

      expect(_registry.readString(_location, 'exact'), exact);
    });

    test('round-trips non-ASCII text', () {
      const korean = r'C:\프로그램\도구.exe';
      _registry.writeString(_location, 'unicode', korean);

      expect(_registry.readString(_location, 'unicode'), korean);
    });

    test('round-trips text outside the basic multilingual plane', () {
      // A surrogate pair is two UTF-16 code units, which is what the byte
      // length arithmetic counts. A character-based count would truncate here.
      const emoji = 'launch 🚀 now';
      _registry.writeString(_location, 'astral', emoji);

      expect(_registry.readString(_location, 'astral'), emoji);
    });

    test('round-trips an empty value', () {
      _registry.writeString(_location, 'empty', '');

      expect(_registry.readString(_location, 'empty'), '');
    });

    test('deletes a value it wrote', () {
      _registry.writeString(_location, 'doomed', 'bye');

      expect(_registry.deleteValue(_location, 'doomed'), isTrue);
      expect(_registry.readString(_location, 'doomed'), isNull);
      expect(regQuery('doomed'), isNull);
    });

    test('reports false when deleting a value that is already absent', () {
      expect(_registry.deleteValue(_location, 'never-existed'), isFalse);
    });

    test('reports false when deleting from a key that does not exist', () {
      const missing = RegistryLocation(
        path: r'Software\just_autostart_test\definitely-absent',
      );

      expect(_registry.deleteValue(missing, 'anything'), isFalse);
    });

    // A value another program stored under a colliding name. Reading it must
    // not throw: both callers read `null` as "not ours", and a crash here would
    // turn `disable()` — documented as safe and idempotent — into a failure.
    test('returns null for a value that is not a string', () {
      final result = Process.runSync('reg', [
        'add',
        r'HKCU\' + _scratchPath,
        '/v',
        'dword',
        '/t',
        'REG_DWORD',
        '/d',
        '1',
        '/f',
      ]);
      expect(result.exitCode, 0, reason: 'reg add should have succeeded');

      expect(_registry.readString(_location, 'dword'), isNull);
    });

    test('writes binary a different reader can see', () {
      _registry.writeBinary(
        _location,
        'bin',
        Uint8List.fromList([0x02, 0x00, 0x00, 0x00]),
      );

      final probe = Process.runSync('reg', [
        'query',
        r'HKCU\' + _scratchPath,
        '/v',
        'bin',
      ]);
      expect(probe.exitCode, 0);
      expect(probe.stdout as String, contains('REG_BINARY'));
      expect(probe.stdout as String, contains('02000000'));
    });

    test('round-trips binary bytes', () {
      final bytes = realDisabledApproval();
      _registry.writeBinary(_location, 'twelve', bytes);

      expect(_registry.readBinary(_location, 'twelve'), bytes);
    });

    // The returned bytes must be a copy: `asTypedList` is a view into arena
    // memory that is freed when the read returns, so a view would hand the
    // caller freed memory. Reading twice and mutating the first result proves
    // the second is unaffected.
    test('returns binary bytes the caller owns', () {
      _registry.writeBinary(_location, 'owned', Uint8List.fromList([1, 2, 3]));

      final first = _registry.readBinary(_location, 'owned')!..[0] = 0xFF;
      final second = _registry.readBinary(_location, 'owned')!;

      expect(first[0], 0xFF);
      expect(second[0], 1);
    });

    test('round-trips binary larger than the fast-path buffer', () {
      final big = Uint8List.fromList(List.generate(1024, (i) => i % 256));
      _registry.writeBinary(_location, 'bigbin', big);

      expect(_registry.readBinary(_location, 'bigbin'), big);
    });

    test('returns null for a binary value that does not exist', () {
      expect(_registry.readBinary(_location, 'no-such-binary'), isNull);
    });

    test('returns null when the value is a string, not binary', () {
      _registry.writeString(_location, 'astring', 'hello');

      expect(_registry.readBinary(_location, 'astring'), isNull);
    });

    test('returns null when the value is binary, not a string', () {
      _registry.writeBinary(_location, 'abinary', Uint8List.fromList([1]));

      expect(_registry.readString(_location, 'abinary'), isNull);
    });

    test('deletes a binary value', () {
      _registry.writeBinary(_location, 'delbin', Uint8List.fromList([1]));

      expect(_registry.deleteValue(_location, 'delbin'), isTrue);
      expect(_registry.readBinary(_location, 'delbin'), isNull);
    });

    test('surfaces an unexpected failure as a typed exception', () {
      // A key name past the 255-character limit is rejected by Windows for any
      // user, so this reaches the failure path with a real Win32 status.
      // Deliberately not HKLM: that would fail only for an unprivileged user
      // and would *succeed* on an elevated CI runner, leaving a key behind and
      // contradicting this package's "current user only" invariant.
      final tooLong = RegistryLocation(path: 'Software\\${'a' * 300}');

      expect(
        () => _registry.writeString(tooLong, 'nope', 'nope'),
        throwsA(
          isA<AutostartOsException>()
              .having((e) => e.operation, 'operation', 'RegCreateKeyExW')
              .having((e) => e.errorCode, 'errorCode', 87)
              .having((e) => e.message, 'message', contains('not valid')),
        ),
      );
    });
  });
}
