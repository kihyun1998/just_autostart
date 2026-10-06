@TestOn('vm')
library;

import 'dart:isolate';

import 'package:just_autostart/just_autostart.dart';
import 'package:test/test.dart';

/// The runtime half of ADR-0003 R4.
///
/// R4 promises a caller that they may move a whole operation off their own
/// isolate — `await Isolate.run(() => autostart.isEnabled())` — and the package
/// owes two guarantees in exchange: everything reachable from an [Autostart] is
/// sendable, and a thrown [AutostartException] crosses the boundary **as its
/// type** rather than degrading into a `RemoteError` string.
///
/// Neither is expressible as a type, which is exactly why they are pinned here.
/// `lessons.md` #14 is the precedent: an invariant the signature cannot carry
/// gets a runtime check, or it is only a sentence.
///
/// **The way it breaks is narrower than it looks, and the intuitive list is
/// wrong.** Measured: `File`, `Directory` and `Pointer` are all *sendable*, so
/// none of them is the hazard. What is unsendable and reachable from this
/// package's vocabulary is **`DynamicLibrary`** — held today as a per-isolate
/// lazy top-level `final` in `com.dart`, `registry.dart` and `current_user.dart`
/// — and `ReceivePort`. A future "resolve the bindings once" refactor that moved
/// a library handle into a field is the realistic change that revokes R4, and
/// these tests are what would notice.
///
/// These tests run on every platform. Sendability is a property of the object
/// graph, not of the operating system, so an unsendable field added on a Windows
/// path is caught by the Linux runner too — which matters, because that is the
/// runner most likely to be green when a Windows-only field lands.
void main() {
  group('ADR-0003 R4 — everything reachable from Autostart is sendable', () {
    final config = AutostartConfig(
      appName: 'ja_isolate_contract',
      label: 'dev.justautostart.isolate.contract',
      executablePath: r'C:\nonexistent\tool.exe',
      args: const ['--daemon'],
    );

    test('the config crosses and arrives equal', () async {
      final round = await Isolate.run(() => config.appName);
      expect(round, 'ja_isolate_contract');
    });

    // Constructing a backend opens nothing — no registry read, no COM apartment,
    // no plist — so this is safe to build for every platform on every runner.
    // What is under test is the object graph, not the operation.
    for (final os in const ['windows', 'macos', 'fuchsia']) {
      test('the $os backend graph crosses intact', () async {
        final autostart = Autostart.forOperatingSystem(config, os);

        final runtimeType = await Isolate.run(
          () => autostart.backend.runtimeType.toString(),
        );

        expect(runtimeType, isNotEmpty);
      });
    }

    test('the Task Scheduler mechanism crosses too', () async {
      final autostart = Autostart.forOperatingSystem(
        config,
        'windows',
        windows: const WindowsAutostartOptions(
          mechanism: WindowsAutostartMechanism.taskScheduler,
          startupDelay: Duration(seconds: 30),
        ),
      );

      final runtimeType = await Isolate.run(
        () => autostart.backend.runtimeType.toString(),
      );

      expect(runtimeType, isNotEmpty);
    });
  });

  group('ADR-0003 R4 — a failure crosses as its type, not as a string', () {
    // One per subclass of the sealed hierarchy. A failure that arrives as a
    // `RemoteError` is `lessons.md` #2's defect reached by a new route: the
    // caller cannot tell what went wrong, on a package whose stated identity is
    // that nothing fails silently.
    //
    // **What this group pins, and what it cannot.** The failure mode is real
    // and was reproduced with a throwaway probe: an exception carrying an
    // unsendable field arrives as `RemoteError`, with the original type gone
    // (`isCarrier=false`). So these assertions can fail. What they cannot do is
    // catch it arriving *here*, because every subclass is `const` — acquiring an
    // unsendable field means dropping `const`, which is a visible change to
    // every call site rather than the quiet one the sendability group above
    // guards. Recorded rather than claimed, per `lessons.md` #24: the group's
    // value is that it would notice an SDK change to `Isolate.run`'s error path,
    // not that it fences a likely edit to this file.
    final thrown = <String, AutostartException>{
      'UnsupportedPlatformException': const UnsupportedPlatformException(
        'fuchsia',
      ),
      'ExecutableNotFoundException': const ExecutableNotFoundException(
        r'C:\nonexistent\tool.exe',
      ),
      'ExecutablePermissionException': const ExecutablePermissionException(
        '/usr/local/bin/tool',
      ),
      'MalformedRegistrationException': const MalformedRegistrationException(
        'the stored value did not parse',
        path: r'C:\nonexistent\tool.exe',
      ),
      'MechanismCleanupException': const MechanismCleanupException(
        ExecutableNotFoundException(r'C:\nonexistent\tool.exe'),
      ),
      'AutostartOsException': const AutostartOsException(
        operation: 'RegSetValueExW',
        detail: 'access denied',
        errorCode: 5,
      ),
    };

    thrown.forEach((name, error) {
      test('$name survives the isolate boundary', () async {
        await expectLater(
          Isolate.run<void>(() => throw error),
          throwsA(
            isA<AutostartException>().having(
              (e) => e.runtimeType.toString(),
              'runtimeType',
              name,
            ),
          ),
        );
      });
    });

    test(
      'the OS error code survives, because that is what a log needs',
      () async {
        try {
          await Isolate.run<void>(
            () => throw const AutostartOsException(
              operation: 'RegSetValueExW',
              detail: 'access denied',
              errorCode: 5,
            ),
          );
          fail('expected the exception to cross');
        } on AutostartOsException catch (error) {
          expect(error.errorCode, 5);
          expect(error.operation, 'RegSetValueExW');
        }
      },
    );
  });
}
