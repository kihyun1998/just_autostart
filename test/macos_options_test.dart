import 'package:just_autostart/just_autostart.dart';
import 'package:test/test.dart';

void main() {
  group('MacosAutostartOptions defaults', () {
    test('configure nothing, so the agent stays minimal', () {
      const options = MacosAutostartOptions();

      expect(options.keepAlive, isNull);
      expect(options.standardOutPath, isNull);
      expect(options.standardErrorPath, isNull);
      expect(options.workingDirectory, isNull);
      expect(options.environment, isEmpty);
      expect(options.activateImmediately, isFalse);
    });

    test('compares by value', () {
      expect(const MacosAutostartOptions(), const MacosAutostartOptions());
      expect(
        const MacosAutostartOptions().hashCode,
        const MacosAutostartOptions().hashCode,
      );
      expect(
        const MacosAutostartOptions(keepAlive: true),
        isNot(const MacosAutostartOptions()),
      );
      expect(
        const MacosAutostartOptions(activateImmediately: true),
        isNot(const MacosAutostartOptions()),
      );
      expect(
        const MacosAutostartOptions(environment: {'A': '1'}),
        isNot(const MacosAutostartOptions(environment: {'A': '2'})),
      );
    });

    test('names its values when printed', () {
      expect(
        const MacosAutostartOptions(keepAlive: true).toString(),
        contains('keepAlive: true'),
      );
    });
  });

  group('MacosAutostartOptions.validate', () {
    test('accepts the default', () {
      expect(const MacosAutostartOptions().validate, returnsNormally);
    });

    test('refuses a blank path', () {
      expect(
        () => const MacosAutostartOptions(standardOutPath: '   ').validate(),
        throwsArgumentError,
      );
    });

    // launchd resolves WorkingDirectory with chdir(2) and opens the log paths
    // itself, in a process whose working directory is not the caller's. A
    // relative path therefore resolves against something the calling
    // application cannot see, so it is refused rather than accepted and quietly
    // pointed somewhere else.
    test('refuses a relative working directory', () {
      expect(
        () => const MacosAutostartOptions(workingDirectory: 'logs').validate(),
        throwsArgumentError,
      );
    });

    test('refuses a relative standard output path', () {
      expect(
        () =>
            const MacosAutostartOptions(standardOutPath: 'out.log').validate(),
        throwsArgumentError,
      );
    });

    test('refuses a relative standard error path', () {
      expect(
        () => const MacosAutostartOptions(
          standardErrorPath: './err.log',
        ).validate(),
        throwsArgumentError,
      );
    });

    test('accepts absolute paths', () {
      expect(
        const MacosAutostartOptions(
          standardOutPath: '/tmp/out.log',
          standardErrorPath: '/tmp/err.log',
          workingDirectory: '/tmp',
        ).validate,
        returnsNormally,
      );
    });

    test('refuses a blank environment variable name', () {
      expect(
        () => const MacosAutostartOptions(environment: {'  ': 'v'}).validate(),
        throwsArgumentError,
      );
    });

    test('refuses an environment variable name containing "="', () {
      // `=` terminates a name, so such a key would silently become a different
      // variable than the caller named.
      expect(
        () => const MacosAutostartOptions(environment: {'A=B': 'v'}).validate(),
        throwsArgumentError,
      );
    });
  });
}
