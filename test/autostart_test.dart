import 'package:just_autostart/src/backends/windows/windows_run_key_backend.dart';
import 'package:just_autostart/src/backends/windows/windows_task_scheduler_backend.dart';
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
  _windowsMechanismTests();
  _windowsRefusalTests();

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

// The mechanism selector. Which Windows mechanism to use is the calling
// application's decision — `CLAUDE.md` names it as policy the package does not
// own — so it reaches the public surface rather than being chosen here.
void _windowsMechanismTests() {
  final config = AutostartConfig(
    appName: 'Test',
    label: 'dev.test',
    executablePath: r'C:\app.exe',
  );

  group('WindowsAutostartOptions', () {
    test('defaults to the registry Run key', () {
      expect(
        const WindowsAutostartOptions().mechanism,
        WindowsAutostartMechanism.runKey,
      );
    });

    // `null`, not `true`: the default means "whatever the chosen mechanism can
    // do", which is what lets an explicit `true` under the `Run` key be
    // refused without also refusing every caller who never thought about it.
    test('leaves the window decision to the mechanism by default', () {
      expect(const WindowsAutostartOptions().hideWindow, isNull);
      expect(const WindowsAutostartOptions().hideWindowOrDefault, isFalse);
      expect(
        const WindowsAutostartOptions(
          mechanism: WindowsAutostartMechanism.taskScheduler,
        ).hideWindowOrDefault,
        isTrue,
      );
    });

    test('defaults to no delay', () {
      expect(const WindowsAutostartOptions().startupDelay, isNull);
    });

    test('compares by value', () {
      expect(const WindowsAutostartOptions(), const WindowsAutostartOptions());
      expect(
        const WindowsAutostartOptions().hashCode,
        const WindowsAutostartOptions().hashCode,
      );
      expect(
        const WindowsAutostartOptions(),
        isNot(
          const WindowsAutostartOptions(
            mechanism: WindowsAutostartMechanism.taskScheduler,
          ),
        ),
      );
    });

    test('names its values when printed', () {
      expect(
        const WindowsAutostartOptions().toString(),
        contains('WindowsAutostartMechanism.runKey'),
      );
    });
  });

  group('Autostart.forOperatingSystem on windows', () {
    test('builds a Run key backend by default', () {
      final autostart = Autostart.forOperatingSystem(config, 'windows');

      expect(autostart.backend, isA<WindowsRunKeyBackend>());
    });

    test('builds a Task Scheduler backend when asked', () {
      final autostart = Autostart.forOperatingSystem(
        config,
        'windows',
        windows: const WindowsAutostartOptions(
          mechanism: WindowsAutostartMechanism.taskScheduler,
        ),
      );

      expect(autostart.backend, isA<WindowsTaskSchedulerBackend>());
    });

    test('passes the window and delay settings to the backend', () {
      final autostart = Autostart.forOperatingSystem(
        config,
        'windows',
        windows: const WindowsAutostartOptions(
          mechanism: WindowsAutostartMechanism.taskScheduler,
          hideWindow: false,
          startupDelay: Duration(seconds: 30),
        ),
      );

      final backend = autostart.backend as WindowsTaskSchedulerBackend;
      expect(backend.hideWindow, isFalse);
      expect(backend.delay, const Duration(seconds: 30));
    });

    // The `Run` key has no way to express a delay. Accepting the value and
    // dropping it would leave a caller believing in a delay that never happens,
    // which is the failure this package refuses everywhere else.
    test('refuses a delay the Run key cannot honour', () {
      expect(
        () => Autostart.forOperatingSystem(
          config,
          'windows',
          windows: const WindowsAutostartOptions(
            startupDelay: Duration(seconds: 30),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('refuses a negative delay', () {
      expect(
        () => Autostart.forOperatingSystem(
          config,
          'windows',
          windows: const WindowsAutostartOptions(
            mechanism: WindowsAutostartMechanism.taskScheduler,
            startupDelay: Duration(seconds: -1),
          ),
        ),
        throwsArgumentError,
      );
    });

    // The options are Windows-only, and a platform with no backend must not
    // start failing merely because they were passed.
    test('ignores the Windows options on another platform', () {
      final autostart = Autostart.forOperatingSystem(
        config,
        'linux',
        windows: const WindowsAutostartOptions(
          mechanism: WindowsAutostartMechanism.taskScheduler,
          startupDelay: Duration(seconds: 30),
        ),
      );

      expect(autostart.backend, isA<UnsupportedPlatformBackend>());
    });
  });
}

// Combinations the selector must refuse rather than silently drop.
void _windowsRefusalTests() {
  final config = AutostartConfig(
    appName: 'Test',
    label: 'dev.test',
    executablePath: r'C:\app.exe',
  );

  Autostart build(WindowsAutostartOptions windows) =>
      Autostart.forOperatingSystem(config, 'windows', windows: windows);

  group('combinations the Run key cannot honour', () {
    // The most consequential thing this package could drop silently: the caller
    // is told autostart is configured and gets a black console window at every
    // login, which is the defect the other mechanism exists to fix.
    test('refuses hideWindow: true under the Run key', () {
      expect(
        () => build(const WindowsAutostartOptions(hideWindow: true)),
        throwsArgumentError,
      );
    });

    test('accepts hideWindow: false under the Run key', () {
      expect(
        build(const WindowsAutostartOptions(hideWindow: false)).backend,
        isA<WindowsRunKeyBackend>(),
      );
    });

    // The default is `null`, meaning "whatever the mechanism can do" — so the
    // ordinary caller who never thinks about it is not refused.
    test('accepts the default under the Run key', () {
      expect(
        build(const WindowsAutostartOptions()).backend,
        isA<WindowsRunKeyBackend>(),
      );
    });

    test('hides the window by default under Task Scheduler', () {
      final backend =
          build(
                const WindowsAutostartOptions(
                  mechanism: WindowsAutostartMechanism.taskScheduler,
                ),
              ).backend
              as WindowsTaskSchedulerBackend;

      expect(backend.hideWindow, isTrue);
    });

    // A scheduled task stores its delay in ISO 8601, which has no unit below a
    // second. Accepting the value and truncating it would register a delay of
    // nothing while the caller believed in half a second.
    test('refuses a sub-second delay', () {
      expect(
        () => build(
          const WindowsAutostartOptions(
            mechanism: WindowsAutostartMechanism.taskScheduler,
            startupDelay: Duration(milliseconds: 500),
          ),
        ),
        throwsArgumentError,
      );
    });

    test('accepts a delay of exactly one second', () {
      expect(
        build(
          const WindowsAutostartOptions(
            mechanism: WindowsAutostartMechanism.taskScheduler,
            startupDelay: Duration(seconds: 1),
          ),
        ).backend,
        isA<WindowsTaskSchedulerBackend>(),
      );
    });
  });
}
