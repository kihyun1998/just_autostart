@TestOn('mac-os')
library;

import 'dart:io';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/macos/launch_agent_plist.dart';
import 'package:just_autostart/src/backends/macos/launchctl.dart';
import 'package:just_autostart/src/backends/macos/macos_autostart_backend.dart';
import 'package:test/test.dart';

/// A launchd override store that never touches the machine.
///
/// Models the disable-override state as a set of labels the user switched off,
/// so a test can plant a veto, watch `enable()` clear it, and read it back —
/// without depending on, or mutating, the developer's real launchd state.
final class FakeLaunchctl implements Launchctl {
  FakeLaunchctl({
    Set<String>? disabled,
    this.available = true,
    this.clearSucceeds = true,
  }) : _disabled = {...?disabled};

  final Set<String> _disabled;

  /// When false, `readDisabledOverrides` returns null — launchctl unavailable.
  final bool available;

  /// When false, `clearOverride` fails and leaves the veto standing.
  final bool clearSucceeds;

  final List<String> clearCalls = [];

  @override
  String? readDisabledOverrides() {
    if (!available) return null;
    final buffer = StringBuffer('\tdisabled services = {\n');
    for (final label in _disabled) {
      buffer.writeln('\t\t"$label" => disabled');
    }
    buffer.write('\t}\n');
    return buffer.toString();
  }

  @override
  bool clearOverride(String label) {
    clearCalls.add(label);
    if (!clearSucceeds) return false;
    _disabled.remove(label);
    return true;
  }
}

void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('just_autostart_macos_test');
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  /// A path that certainly exists, so `enable()` gets past its existence check.
  final realExecutable = Platform.resolvedExecutable;

  AutostartConfig config({
    String? executablePath,
    List<String> args = const [],
    String label = 'dev.justautostart.test',
  }) {
    return AutostartConfig(
      appName: 'JustAutostartTest',
      label: label,
      executablePath: executablePath ?? realExecutable,
      args: args,
    );
  }

  MacosAutostartBackend backend({
    String? executablePath,
    List<String> args = const [],
    String label = 'dev.justautostart.test',
    Directory? directory,
    Launchctl? launchctl,
  }) {
    return MacosAutostartBackend(
      config: config(executablePath: executablePath, args: args, label: label),
      launchAgentsDirectory: directory ?? scratch,
      // A fake by default, so the #8 behaviours stay off the real machine now
      // that isEnabled() and enable() consult launchctl.
      launchctl: launchctl ?? FakeLaunchctl(),
    );
  }

  File plistFile(String label) => File('${scratch.path}/$label.plist');

  group('enable', () {
    test('writes a plist named after the label', () async {
      await backend(label: 'dev.justautostart.named').enable();

      expect(plistFile('dev.justautostart.named').existsSync(), isTrue);
    });

    test('writes a plist Apple\'s own parser accepts', () async {
      await backend(args: const ['--daemon']).enable();

      // The tautological-proof guard: our writer agreeing with our reader
      // proves nothing about whether launchd will accept the file. plutil is
      // Apple's parser.
      final lint = Process.runSync('plutil', [
        '-lint',
        plistFile('dev.justautostart.test').path,
      ]);
      expect(lint.exitCode, 0, reason: '${lint.stdout}${lint.stderr}');
    });

    test('names the configured executable and arguments', () async {
      // A real file, because enable() rejects a path that does not exist. Its
      // directory and name carry XML-special characters, so escaping is proven
      // through a genuine path, not only a synthetic string.
      final exeDir = Directory('${scratch.path}/My Tools & <bin>')
        ..createSync();
      final exe = File('${exeDir.path}/tool')..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['+x', exe.path]);

      await backend(
        executablePath: exe.path,
        args: const ['--port=8080', 'a<b>&c'],
      ).enable();

      final parsed = parseLaunchAgentPlist(
        plistFile('dev.justautostart.test').readAsStringSync(),
      );
      expect(parsed.executablePath, exe.path);
      expect(parsed.args, ['--port=8080', 'a<b>&c']);
    });

    test('is idempotent — enabling twice leaves one valid agent', () async {
      final b = backend();
      await b.enable();
      await b.enable();

      final files = scratch
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.plist'))
          .toList();
      expect(files, hasLength(1));
      expect(await b.isEnabled(), isTrue);
    });

    test('rejects an executable that does not exist', () async {
      expect(
        () => backend(executablePath: '/no/such/binary').enable(),
        throwsA(isA<ExecutableNotFoundException>()),
      );
    });

    test('rejects a file that exists but has no execute permission', () async {
      // The installer bug this catches at dev time: a binary shipped or copied
      // without its execute bit. It exists, so the existence check passes, but
      // launchd's execvp fails with EACCES at login and nothing starts.
      final notExec = File('${scratch.path}/tool')
        ..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', ['644', notExec.path]);

      expect(
        () => backend(executablePath: notExec.path).enable(),
        throwsA(isA<ExecutablePermissionException>()),
      );
    });

    test('surfaces an unwritable directory as an OS exception', () async {
      // Point the directory under a regular file: creating it must fail.
      final blocker = File('${scratch.path}/blocker')..writeAsStringSync('x');
      final b = backend(directory: Directory('${blocker.path}/nested'));

      expect(() => b.enable(), throwsA(isA<AutostartOsException>()));
    });
  });

  group('disable', () {
    test('removes the agent', () async {
      final b = backend();
      await b.enable();
      expect(plistFile('dev.justautostart.test').existsSync(), isTrue);

      await b.disable();
      expect(plistFile('dev.justautostart.test').existsSync(), isFalse);
    });

    test(
      'is idempotent — disabling when nothing is registered is a no-op',
      () async {
        await backend().disable();
        // Reaching here without throwing is the assertion.
      },
    );

    test('leaves a foreign agent that merely shares our file name', () async {
      // launchd identifies a job by its internal Label, not the file name. A
      // third party's plist can legally sit at <our-label>.plist; deleting it
      // on a name match alone would destroy their registration, unrecoverably.
      final foreign = plistFile('dev.justautostart.test')
        ..writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.vendorx.updater</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/VendorX.app/Contents/MacOS/updater</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
''');

      await backend().disable();

      expect(foreign.existsSync(), isTrue);
    });

    test('leaves a file it cannot confirm is its own', () async {
      // A malformed file at our path cannot be attributed. disable() must not
      // delete what it cannot read as ours, and must not throw.
      final corrupt = plistFile('dev.justautostart.test')
        ..writeAsStringSync('<plist><dict><key>Label</key');

      await backend().disable();

      expect(corrupt.existsSync(), isTrue);
    });
  });

  group('isEnabled', () {
    test('is false when no plist exists', () async {
      expect(await backend().isEnabled(), isFalse);
    });

    test(
      'is true when the plist names the configured executable and args',
      () async {
        final b = backend(args: const ['--daemon']);
        await b.enable();

        expect(await b.isEnabled(), isTrue);
      },
    );

    test('is false when the plist points at a different executable', () async {
      // Enable one executable, then ask a backend configured for another.
      await backend(executablePath: realExecutable).enable();

      final other = MacosAutostartBackend(
        config: config(executablePath: '/opt/other/tool'),
        launchAgentsDirectory: scratch,
      );
      expect(await other.isEnabled(), isFalse);
    });

    test('is false when the arguments differ', () async {
      await backend(args: const ['--daemon']).enable();

      final other = backend(args: const ['--interactive']);
      expect(await other.isEnabled(), isFalse);
    });

    test('is false when the plist has RunAtLoad off', () async {
      // A registration that will not start at login. isEnabled() reports what
      // will actually launch, so ProgramArguments matching is not enough.
      plistFile('dev.justautostart.test').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.justautostart.test</string>
	<key>ProgramArguments</key>
	<array>
		<string>${Platform.resolvedExecutable}</string>
	</array>
	<key>RunAtLoad</key>
	<false/>
</dict>
</plist>
''');

      expect(await backend().isEnabled(), isFalse);
    });

    test('is false when the plist is disabled inside the file', () async {
      plistFile('dev.justautostart.test').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.justautostart.test</string>
	<key>Disabled</key>
	<true/>
	<key>ProgramArguments</key>
	<array>
		<string>${Platform.resolvedExecutable}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
''');

      expect(await backend().isEnabled(), isFalse);
    });

    test('enable() clears a stale in-plist Disabled', () async {
      // enable() rewrites the whole file, so a pre-existing Disabled=true does
      // not survive — there is no path where enable() returns and isEnabled()
      // is still false because of a store enable() itself wrote.
      plistFile('dev.justautostart.test').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>dev.justautostart.test</string>
	<key>Disabled</key>
	<true/>
	<key>ProgramArguments</key>
	<array>
		<string>${Platform.resolvedExecutable}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
''');

      final b = backend();
      await b.enable();

      expect(await b.isEnabled(), isTrue);
    });

    test('throws when the plist at our own path is corrupt', () async {
      final file = plistFile('dev.justautostart.test')
        ..writeAsStringSync('<plist><dict><key>Label</key');

      expect(
        () => backend().isEnabled(),
        throwsA(
          isA<MalformedRegistrationException>().having(
            (e) => e.path,
            'path',
            file.path,
          ),
        ),
      );
    });
  });

  group('the Login Items veto (launchd disable overrides)', () {
    const label = 'dev.justautostart.test';

    test('isEnabled is false when the user switched the agent off', () async {
      // The plist is present and correct; only the user's System Settings veto
      // stands. A check of the file alone would wrongly report enabled.
      plistFile(label).writeAsStringSync(
        generateLaunchAgentPlist(
          label: label,
          executablePath: realExecutable,
          args: const [],
        ),
      );

      final b = backend(launchctl: FakeLaunchctl(disabled: {label}));
      expect(await b.isEnabled(), isFalse);
    });

    test(
      'isEnabled degrades to enabled when launchctl cannot be read',
      () async {
        await backend().enable();

        final b = backend(launchctl: FakeLaunchctl(available: false));
        expect(await b.isEnabled(), isTrue);
      },
    );

    test('enable clears a standing veto', () async {
      final launchctl = FakeLaunchctl(disabled: {label});
      final b = backend(launchctl: launchctl);

      await b.enable();

      expect(launchctl.clearCalls, contains(label));
      expect(await b.isEnabled(), isTrue);
    });

    test('no path leaves enable successful while isEnabled is false', () async {
      // The pairing the whole ticket exists to guarantee: after enable() returns
      // without throwing, isEnabled() is true.
      final b = backend(launchctl: FakeLaunchctl(disabled: {label}));

      await b.enable();

      expect(await b.isEnabled(), isTrue);
    });

    test('enable throws when it cannot clear a standing veto', () async {
      // If the veto stands and cannot be cleared, enable() must not return
      // success — that is exactly the silent-failure the identity forbids.
      final b = backend(
        launchctl: FakeLaunchctl(disabled: {label}, clearSucceeds: false),
      );

      expect(() => b.enable(), throwsA(isA<AutostartOsException>()));
    });

    test('enable succeeds when launchctl is unavailable', () async {
      // No override is knowable, so there is nothing to clear and no
      // contradiction to guard against — enable() proceeds.
      final b = backend(launchctl: FakeLaunchctl(available: false));

      await b.enable();

      expect(await b.isEnabled(), isTrue);
    });
  });

  group('against the real launchctl', () {
    test('reads the real override roster, or degrades, without throwing', () {
      // The one integration test the ticket asks for: the real
      // `launchctl print-disabled gui/<uid>` is invoked, and its absence — a
      // headless runner with no GUI domain — is handled gracefully by returning
      // null rather than throwing.
      //
      // Read-only on purpose. `launchctl enable` (the clear path) writes a
      // durable row into the user's shared override store with no clean way to
      // remove it, so exercising it here would litter real OS state (lessons
      // #8). That path is proven instead by the throwaway measurement recorded
      // in issue #9, and its logic by the FakeLaunchctl tests above.
      final overrides = const SystemLaunchctl().readDisabledOverrides();

      // Either the real roster (a GUI session) or null (headless) — never a
      // throw, and when present it is the format the parser expects.
      expect(
        overrides == null || overrides.contains('disabled services'),
        isTrue,
      );
    });
  });
}
