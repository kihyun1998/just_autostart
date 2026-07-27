@TestOn('windows')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:just_autostart/src/backends/windows/run_command_line.dart';
import 'package:test/test.dart';

/// Splits a command line with the parser Windows itself uses.
///
/// `encodeRunCommandLine` round-tripping through `decodeRunCommandLine` proves
/// only that this package agrees with itself — a tautological proof, and the one
/// the bindings doc names explicitly. What actually matters is whether
/// **Windows** recovers the arguments, because Windows is what parses the `Run`
/// value at login. So the assertion goes through `CommandLineToArgvW`.
List<String> parseWithWindows(String commandLine) {
  return using((arena) {
    final count = arena<Int32>();
    final argv = _commandLineToArgvW(
      commandLine.toNativeUtf16(allocator: arena),
      count,
    );
    if (argv == nullptr) {
      throw StateError('CommandLineToArgvW rejected: $commandLine');
    }
    try {
      return [for (var i = 0; i < count.value; i++) argv[i].toDartString()];
    } finally {
      // The array is LocalAlloc'd by the API and is the caller's to release.
      _localFree(argv.cast());
    }
  });
}

void main() {
  group('Windows parses what we encode', () {
    const cases = <(String, List<String>)>[
      (r'C:\app.exe', []),
      (r'C:\Program Files\My Tool\mytool.exe', []),
      (r'C:\app.exe', ['--daemon']),
      (r'C:\Program Files\My Tool\mytool.exe', ['--daemon', '-v']),
      (r'C:\app.exe', [r'--out=C:\My Docs']),
      (r'C:\app.exe', ['say "hi"']),
      (r'C:\app.exe', [r'C:\my dir\']),
      (r'C:\app.exe', [r'C:\dir\']),
      (r'C:\app.exe', [r'a\b\c']),
      (r'C:\app.exe', ['a\tb', 'plain']),
      (r'C:\app.exe', [r'ends\\with\\backslashes\\']),
      (r'C:\app.exe', [r'"leading quote']),
      (r'C:\app.exe', ['multiple', 'plain', 'args']),
      (r'C:\프로그램\도구.exe', ['한글 인자']),
    ];

    for (final (path, args) in cases) {
      test('$path with $args', () {
        final encoded = encodeRunCommandLine(path, args);

        expect(parseWithWindows(encoded), [path, ...args]);
      });
    }

    // An empty argument survives our own round trip, but CommandLineToArgvW
    // is the authority on whether Windows hands it to the program. Pinning the
    // real behaviour here means a future encoder change cannot quietly alter it.
    test('an empty argument', () {
      final encoded = encodeRunCommandLine(r'C:\app.exe', const ['']);

      expect(parseWithWindows(encoded), [r'C:\app.exe', '']);
    });
  });

  group('our decoder agrees with Windows', () {
    // Values in this package's canonical form must be split the same way by
    // both parsers. Where they disagree, Windows is right — it is the one that
    // runs at login.
    const values = [
      r'"C:\app.exe" --daemon',
      r'"C:\Program Files\My Tool\mytool.exe" --out="C:\My Docs"',
      r'"C:\app.exe" "say \"hi\"" plain',
      r'"C:\app.exe"',
    ];

    for (final value in values) {
      test(value, () {
        final decoded = decodeRunCommandLine(value);
        expect(decoded, isNotNull);

        expect([
          decoded!.executablePath,
          ...decoded.args,
        ], parseWithWindows(value));
      });
    }
  });
}

final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final _commandLineToArgvW = _shell32
    .lookupFunction<
      Pointer<Pointer<Utf16>> Function(Pointer<Utf16>, Pointer<Int32>),
      Pointer<Pointer<Utf16>> Function(Pointer<Utf16>, Pointer<Int32>)
    >('CommandLineToArgvW');

final _localFree = _kernel32
    .lookupFunction<Pointer Function(Pointer), Pointer Function(Pointer)>(
      'LocalFree',
    );
