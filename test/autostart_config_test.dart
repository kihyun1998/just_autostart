import 'package:just_autostart/just_autostart.dart';
import 'package:test/test.dart';

void main() {
  group('AutostartConfig', () {
    test('keeps the values it was given', () {
      final config = AutostartConfig(
        appName: 'My Tool',
        label: 'com.example.mytool',
        executablePath: r'C:\Program Files\My Tool\mytool.exe',
        args: const ['--daemon', '--verbose'],
      );

      expect(config.appName, 'My Tool');
      expect(config.label, 'com.example.mytool');
      expect(config.executablePath, r'C:\Program Files\My Tool\mytool.exe');
      expect(config.args, ['--daemon', '--verbose']);
    });

    test('defaults to no arguments', () {
      final config = AutostartConfig(
        appName: 'My Tool',
        label: 'com.example.mytool',
        executablePath: '/usr/local/bin/mytool',
      );

      expect(config.args, isEmpty);
    });

    test('exposes arguments as an unmodifiable list', () {
      final config = AutostartConfig(
        appName: 'My Tool',
        label: 'com.example.mytool',
        executablePath: '/usr/local/bin/mytool',
        args: const ['--daemon'],
      );

      expect(() => config.args.add('--sneaky'), throwsUnsupportedError);
    });

    test('rejects an empty app name', () {
      expect(
        () => AutostartConfig(
          appName: '   ',
          label: 'com.example.mytool',
          executablePath: '/usr/local/bin/mytool',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an empty label', () {
      expect(
        () => AutostartConfig(
          appName: 'My Tool',
          label: '',
          executablePath: '/usr/local/bin/mytool',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an empty executable path', () {
      expect(
        () => AutostartConfig(
          appName: 'My Tool',
          label: 'com.example.mytool',
          executablePath: '  ',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    // The label becomes a file name on macOS, so a separator in it would let a
    // caller write outside the directory the backend targets.
    test('rejects a label containing a path separator', () {
      for (final label in [
        'com.example/mytool',
        r'com.example\mytool',
        '../com.example.mytool',
      ]) {
        expect(
          () => AutostartConfig(
            appName: 'My Tool',
            label: label,
            executablePath: '/usr/local/bin/mytool',
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'label "$label" should be rejected',
        );
      }
    });

    test('is equal to another config with the same values', () {
      AutostartConfig build() => AutostartConfig(
        appName: 'My Tool',
        label: 'com.example.mytool',
        executablePath: '/usr/local/bin/mytool',
        args: const ['--daemon'],
      );

      expect(build(), build());
      expect(build().hashCode, build().hashCode);
    });

    test('differs when the arguments differ', () {
      final withArgs = AutostartConfig(
        appName: 'My Tool',
        label: 'com.example.mytool',
        executablePath: '/usr/local/bin/mytool',
        args: const ['--daemon'],
      );
      final withoutArgs = AutostartConfig(
        appName: 'My Tool',
        label: 'com.example.mytool',
        executablePath: '/usr/local/bin/mytool',
      );

      expect(withArgs, isNot(withoutArgs));
    });
  });
}
