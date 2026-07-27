import 'package:just_autostart/src/backends/windows/run_command_line.dart';
import 'package:test/test.dart';

void main() {
  group('encodeRunCommandLine', () {
    test('quotes the executable path even when it has no spaces', () {
      expect(encodeRunCommandLine(r'C:\app.exe', const []), r'"C:\app.exe"');
    });

    test('quotes an executable path containing spaces', () {
      expect(
        encodeRunCommandLine(r'C:\Program Files\My Tool\mytool.exe', const []),
        r'"C:\Program Files\My Tool\mytool.exe"',
      );
    });

    test('appends plain arguments unquoted', () {
      expect(
        encodeRunCommandLine(r'C:\app.exe', const ['--daemon', '-v']),
        r'"C:\app.exe" --daemon -v',
      );
    });

    test('quotes an argument containing a space', () {
      expect(
        encodeRunCommandLine(r'C:\app.exe', const [r'--out=C:\My Docs']),
        r'"C:\app.exe" "--out=C:\My Docs"',
      );
    });

    test('quotes an argument containing a tab', () {
      expect(
        encodeRunCommandLine(r'C:\app.exe', const ['a\tb']),
        '"C:\\app.exe" "a\tb"',
      );
    });

    test('escapes a quote inside an argument', () {
      expect(
        encodeRunCommandLine(r'C:\app.exe', const ['say "hi"']),
        r'"C:\app.exe" "say \"hi\""',
      );
    });

    test('doubles backslashes that precede an escaped quote', () {
      // CommandLineToArgvW only treats a backslash as an escape when a quote
      // follows it, so a trailing backslash before the closing quote has to be
      // doubled or it escapes the terminator.
      expect(
        encodeRunCommandLine(r'C:\app.exe', const [r'C:\dir\']),
        r'"C:\app.exe" C:\dir\',
      );
      expect(
        encodeRunCommandLine(r'C:\app.exe', const [r'C:\my dir\']),
        r'"C:\app.exe" "C:\my dir\\"',
      );
    });

    test('leaves interior backslashes alone when no quote follows', () {
      expect(
        encodeRunCommandLine(r'C:\app.exe', const [r'a\b\c']),
        r'"C:\app.exe" a\b\c',
      );
    });

    test('quotes an empty argument so it survives the round trip', () {
      expect(
        encodeRunCommandLine(r'C:\app.exe', const ['']),
        r'"C:\app.exe" ""',
      );
    });
  });

  group('decodeRunCommandLine', () {
    test('reads back a path with no arguments', () {
      final decoded = decodeRunCommandLine(r'"C:\app.exe"');

      expect(decoded, isNotNull);
      expect(decoded!.executablePath, r'C:\app.exe');
      expect(decoded.args, isEmpty);
    });

    test('reads back a path containing spaces', () {
      final decoded = decodeRunCommandLine(
        r'"C:\Program Files\My Tool\mytool.exe"',
      );

      expect(decoded!.executablePath, r'C:\Program Files\My Tool\mytool.exe');
    });

    // The whole point of the canonical form: anything we did not write decodes
    // to null, which is what stops `disable()` deleting a third party's entry.
    test('refuses a value with an unquoted executable path', () {
      expect(decodeRunCommandLine(r'C:\app.exe --daemon'), isNull);
      expect(decodeRunCommandLine(r'C:\Program Files\app.exe'), isNull);
    });

    test('refuses an empty or malformed value', () {
      expect(decodeRunCommandLine(''), isNull);
      expect(decodeRunCommandLine('   '), isNull);
      expect(decodeRunCommandLine('"unterminated'), isNull);
      expect(decodeRunCommandLine('""'), isNull);
    });

    test('tolerates leading and trailing whitespace', () {
      final decoded = decodeRunCommandLine('  "C:\\app.exe" --daemon  ');

      expect(decoded!.executablePath, r'C:\app.exe');
      expect(decoded.args, ['--daemon']);
    });
  });

  group('round trip', () {
    const cases = <(String, List<String>)>[
      (r'C:\app.exe', []),
      (r'C:\Program Files\My Tool\mytool.exe', []),
      (r'C:\app.exe', ['--daemon']),
      (r'C:\app.exe', ['--daemon', '-v', '--quiet']),
      (r'C:\app.exe', [r'--out=C:\My Docs']),
      (r'C:\app.exe', ['say "hi"']),
      (r'C:\app.exe', [r'C:\my dir\']),
      (r'C:\app.exe', ['']),
      (r'C:\app.exe', ['a\tb', 'plain']),
    ];

    for (final (path, args) in cases) {
      test('$path with $args', () {
        final decoded = decodeRunCommandLine(encodeRunCommandLine(path, args));

        expect(decoded, isNotNull, reason: 'our own output must decode');
        expect(decoded!.executablePath, path);
        expect(decoded.args, args);
      });
    }
  });

  group('RunCommandLine', () {
    test('is equal to another with the same values', () {
      const a = RunCommandLine(
        executablePath: r'C:\app.exe',
        args: ['--daemon'],
      );
      const b = RunCommandLine(
        executablePath: r'C:\app.exe',
        args: ['--daemon'],
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differs when the arguments differ', () {
      const a = RunCommandLine(executablePath: r'C:\app.exe', args: ['--a']);
      const b = RunCommandLine(executablePath: r'C:\app.exe', args: ['--b']);

      expect(a, isNot(b));
    });
  });
}
