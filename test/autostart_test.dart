import 'package:just_autostart/just_autostart.dart';
import 'package:test/test.dart';

/// Records what the facade forwarded, so the delegation can be observed
/// without touching an operating system.
final class _RecordingBackend implements AutostartBackend {
  final List<String> calls = [];
  bool enabled = false;

  @override
  Future<void> enable() async => calls.add('enable');

  @override
  Future<void> disable() async => calls.add('disable');

  @override
  Future<bool> isEnabled() async {
    calls.add('isEnabled');
    return enabled;
  }
}

AutostartConfig _config() => AutostartConfig(
  appName: 'My Tool',
  label: 'com.example.mytool',
  executablePath: '/usr/local/bin/mytool',
);

void main() {
  group('Autostart', () {
    test('forwards enable() to its backend', () async {
      final backend = _RecordingBackend();

      await Autostart.withBackend(backend).enable();

      expect(backend.calls, ['enable']);
    });

    test('forwards disable() to its backend', () async {
      final backend = _RecordingBackend();

      await Autostart.withBackend(backend).disable();

      expect(backend.calls, ['disable']);
    });

    test('returns what its backend reports from isEnabled()', () async {
      final backend = _RecordingBackend()..enabled = true;

      expect(await Autostart.withBackend(backend).isEnabled(), isTrue);
      expect(backend.calls, ['isEnabled']);
    });

    test('propagates failures from its backend untouched', () {
      expect(
        Autostart.withBackend(
          const UnsupportedPlatformBackend('linux'),
        ).enable(),
        throwsA(isA<UnsupportedPlatformException>()),
      );
    });
  });

  group('Autostart.forOperatingSystem', () {
    test('serves an unsupported operating system with a failing backend', () {
      final autostart = Autostart.forOperatingSystem(_config(), 'linux');

      expect(
        autostart.enable(),
        throwsA(
          isA<UnsupportedPlatformException>().having(
            (e) => e.operatingSystem,
            'operatingSystem',
            'linux',
          ),
        ),
      );
    });

    test('names the operating system it was asked about', () {
      expect(
        Autostart.forOperatingSystem(_config(), 'fuchsia').isEnabled(),
        throwsA(
          isA<UnsupportedPlatformException>().having(
            (e) => e.operatingSystem,
            'operatingSystem',
            'fuchsia',
          ),
        ),
      );
    });

    test('builds a backend for every operating system it is given', () {
      for (final os in ['windows', 'macos', 'linux', 'plan9']) {
        expect(
          Autostart.forOperatingSystem(_config(), os),
          isA<Autostart>(),
          reason: 'dispatch must not fall through for "$os"',
        );
      }
    });
  });

  group('Autostart.forCurrentPlatform', () {
    test('builds without inspecting anything but the running platform', () {
      expect(Autostart.forCurrentPlatform(_config()), isA<Autostart>());
    });
  });
}
