import 'package:just_autostart/just_autostart.dart';
import 'package:test/test.dart';

void main() {
  group('resolveAutostartPlatform', () {
    test('recognises windows', () {
      expect(resolveAutostartPlatform('windows'), AutostartPlatform.windows);
    });

    test('recognises macos', () {
      expect(resolveAutostartPlatform('macos'), AutostartPlatform.macos);
    });

    test('treats every other operating system as unsupported', () {
      for (final os in ['linux', 'android', 'ios', 'fuchsia']) {
        expect(
          resolveAutostartPlatform(os),
          AutostartPlatform.unsupported,
          reason: '"$os" has no autostart backend',
        );
      }
    });

    test('treats an unknown operating system as unsupported', () {
      expect(resolveAutostartPlatform('plan9'), AutostartPlatform.unsupported);
      expect(resolveAutostartPlatform(''), AutostartPlatform.unsupported);
    });

    // Platform.operatingSystem is documented as lower case, so an exact match
    // is correct — but a caller passing the string through by hand should not
    // be silently misrouted to the unsupported backend.
    test('is case insensitive', () {
      expect(resolveAutostartPlatform('Windows'), AutostartPlatform.windows);
      expect(resolveAutostartPlatform('macOS'), AutostartPlatform.macos);
    });
  });
}
