import 'package:just_autostart/just_autostart.dart';
import 'package:test/test.dart';

void main() {
  group('UnsupportedPlatformBackend', () {
    const backend = UnsupportedPlatformBackend('linux');

    test('enable() reports the platform it cannot serve', () {
      expect(
        backend.enable(),
        throwsA(
          isA<UnsupportedPlatformException>().having(
            (e) => e.operatingSystem,
            'operatingSystem',
            'linux',
          ),
        ),
      );
    });

    test('disable() reports the platform it cannot serve', () {
      expect(backend.disable(), throwsA(isA<UnsupportedPlatformException>()));
    });

    test('isEnabled() reports the platform it cannot serve', () {
      expect(backend.isEnabled(), throwsA(isA<UnsupportedPlatformException>()));
    });

    test('names the operating system in its message', () {
      expect(
        backend.enable(),
        throwsA(
          isA<UnsupportedPlatformException>().having(
            (e) => e.toString(),
            'toString()',
            contains('linux'),
          ),
        ),
      );
    });
  });

  group('AutostartException', () {
    test('UnsupportedPlatformException is an AutostartException', () {
      expect(
        const UnsupportedPlatformException('linux'),
        isA<AutostartException>(),
      );
    });

    test('ExecutableNotFoundException carries the path it looked for', () {
      const exception = ExecutableNotFoundException('/usr/local/bin/missing');

      expect(exception, isA<AutostartException>());
      expect(exception.executablePath, '/usr/local/bin/missing');
      expect(exception.toString(), contains('/usr/local/bin/missing'));
    });

    test('AutostartOsException carries the failing operation and code', () {
      const exception = AutostartOsException(
        operation: 'RegSetValueExW',
        detail: 'Access is denied',
        errorCode: 5,
      );

      expect(exception, isA<AutostartException>());
      expect(exception.operation, 'RegSetValueExW');
      expect(exception.errorCode, 5);
      expect(exception.toString(), contains('RegSetValueExW'));
      expect(exception.toString(), contains('5'));
    });

    // What the platform said stays readable on its own, so a caller can log or
    // match on it without parsing the assembled message back apart.
    test('AutostartOsException keeps the platform detail unedited', () {
      const exception = AutostartOsException(
        operation: 'RegSetValueExW',
        detail: 'Access is denied',
        errorCode: 5,
      );

      expect(exception.detail, 'Access is denied');
    });

    test('AutostartOsException tolerates a missing error code', () {
      const exception = AutostartOsException(
        operation: 'launchctl bootstrap',
        detail: 'command not found',
      );

      expect(exception.errorCode, isNull);
      expect(exception.toString(), contains('launchctl bootstrap'));
    });
  });
}
