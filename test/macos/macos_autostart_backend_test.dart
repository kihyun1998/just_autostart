@TestOn('mac-os')
library;

import 'dart:io';

import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/macos/launch_agent_plist.dart';
import 'package:just_autostart/src/backends/macos/launchctl.dart';
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

  /// Every session command in the order it was issued, so a test can pin the
  /// ordering `disable()` depends on.
  final List<String> sessionCalls = [];

  /// Whether a bootstrap is allowed to succeed.
  bool bootstrapSucceeds = true;

  /// Whether the agent is currently loaded into the session.
  bool loaded = false;

  /// Run when `bootout` is called, so a test can observe the state at that
  /// moment — the plist must still exist when the agent is booted out.
  void Function()? onBootout;

  @override
  bool bootstrap(String plistPath) {
    sessionCalls.add('bootstrap:$plistPath');
    if (!bootstrapSucceeds) return false;
    loaded = true;
    return true;
  }

  @override
  bool bootout(String label) {
    sessionCalls.add('bootout:$label');
    onBootout?.call();
    if (!loaded) return false;
    loaded = false;
    return true;
  }

  @override
  bool isLoaded(String label) => loaded;

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

  group('plist permissions', () {
    const label = 'dev.justautostart.test';

    /// The mode bits, as the octal a human reads.
    String modeOf(File file) => (file.statSync().mode & 0xFFF).toRadixString(8);

    test('a permissive umask cannot leave the agent group-writable', () async {
      // launchd refuses a job definition writable by group or other, and the
      // refusal is silent — the file is there, parses, and nothing launches.
      // Measured: the same plist loads at 0644 and fails with "Bootstrap
      // failed: 5" at 0666. Writing inherits the umask, so this pre-creates the
      // file the way `umask 0` would leave it; writeAsStringSync keeps an
      // existing file's mode.
      final file = plistFile(label)..writeAsStringSync('placeholder');
      Process.runSync('chmod', ['666', file.path]);
      expect(modeOf(file), '666', reason: 'precondition');

      await backend().enable();

      final mode = file.statSync().mode;
      expect(
        mode & 0x10,
        0,
        reason: 'group must not have write: ${modeOf(file)}',
      );
      expect(
        mode & 0x2,
        0,
        reason: 'other must not have write: ${modeOf(file)}',
      );
    });

    test('a stricter mode is preserved rather than loosened to 644', () async {
      // Restricting means clearing the group/other write bits, not forcing a
      // mode: a caller who deliberately made the file private keeps it private.
      final file = plistFile(label)..writeAsStringSync('placeholder');
      Process.runSync('chmod', ['600', file.path]);

      await backend().enable();

      expect(modeOf(file), '600');
    });

    test('isEnabled is false while the plist is group-writable', () async {
      // A registration launchd will reject is not an enabled one, and this is
      // the same class as RunAtLoad or the in-plist Disabled key: present, well
      // formed, and inert.
      final b = backend();
      await b.enable();
      expect(await b.isEnabled(), isTrue, reason: 'precondition');

      Process.runSync('chmod', ['666', plistFile(label).path]);

      expect(await b.isEnabled(), isFalse);
    });

    test('the written agent is one launchd actually accepts', () async {
      // The end-to-end form of the same claim, against the real command.
      final file = plistFile(label)..writeAsStringSync('placeholder');
      Process.runSync('chmod', ['666', file.path]);

      await MacosAutostartBackend(
        config: AutostartConfig(
          appName: 'JustAutostartPermTest',
          label: label,
          executablePath: '/usr/bin/true',
        ),
        launchAgentsDirectory: scratch,
      ).enable();

      addTearDown(() => const SystemLaunchctl().bootout(label));
      expect(const SystemLaunchctl().bootstrap(file.path), isTrue);
    });
  });

  group('optional agent configuration', () {
    test('reaches the written file only when configured', () async {
      await MacosAutostartBackend(
        config: config(),
        launchAgentsDirectory: scratch,
        launchctl: FakeLaunchctl(),
        options: const MacosAutostartOptions(
          keepAlive: true,
          standardOutPath: '/tmp/out.log',
          standardErrorPath: '/tmp/err.log',
          workingDirectory: '/tmp',
          environment: {'MODE': 'daemon'},
        ),
      ).enable();

      final parsed = parseLaunchAgentPlist(
        plistFile('dev.justautostart.test').readAsStringSync(),
      );
      expect(parsed.keepAlive, isTrue);
      expect(parsed.standardOutPath, '/tmp/out.log');
      expect(parsed.standardErrorPath, '/tmp/err.log');
      expect(parsed.workingDirectory, '/tmp');
      expect(parsed.environment, {'MODE': 'daemon'});
    });

    test('a caller who configures nothing gets the minimal agent', () async {
      await backend().enable();

      final xml = plistFile('dev.justautostart.test').readAsStringSync();
      expect(xml, isNot(contains('KeepAlive')));
      expect(xml, isNot(contains('StandardOutPath')));
      expect(xml, isNot(contains('StandardErrorPath')));
      expect(xml, isNot(contains('WorkingDirectory')));
      expect(xml, isNot(contains('EnvironmentVariables')));
    });

    test('a fully configured plist is still one Apple accepts', () async {
      await MacosAutostartBackend(
        config: config(),
        launchAgentsDirectory: scratch,
        launchctl: FakeLaunchctl(),
        options: const MacosAutostartOptions(
          keepAlive: true,
          standardOutPath: '/tmp/out & log.txt',
          workingDirectory: '/opt/My Tools & <x>',
          environment: {'A&B': '<v>'},
        ),
      ).enable();

      // Our writer agreeing with our reader proves nothing about launchd.
      final lint = Process.runSync('plutil', [
        '-lint',
        plistFile('dev.justautostart.test').path,
      ]);
      expect(lint.exitCode, 0, reason: '${lint.stdout}${lint.stderr}');
    });

    test('isEnabled ignores optional keys it was not configured with', () async {
      // The optional settings describe *how* the agent runs, not *what* is
      // registered, so a registration that differs only there is still ours and
      // still enabled. Only the executable, arguments, and the enablement
      // stores decide.
      await MacosAutostartBackend(
        config: config(),
        launchAgentsDirectory: scratch,
        launchctl: FakeLaunchctl(),
        options: const MacosAutostartOptions(keepAlive: true),
      ).enable();

      expect(await backend().isEnabled(), isTrue);
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

    test('re-checks ownership after the bootout, and refuses a swap', () async {
      // The load-bearing test for #22. The first guard reads the *bytes*; the
      // delete acts on the *path*. Between them `disable()` spawns a process,
      // measured at ~3.2 ms of the window on macOS 14.5, so a plist that
      // becomes somebody else's in that gap would be deleted by a check that
      // never saw it. FakeLaunchctl.onBootout is the only seam that can move
      // the file at exactly that moment.
      final launchctl = FakeLaunchctl();
      final b = backend(launchctl: launchctl);
      await b.enable();

      final file = plistFile('dev.justautostart.test');
      launchctl.onBootout = () => file.writeAsStringSync(
        generateLaunchAgentPlist(
          label: 'com.vendorx.updater',
          executablePath: realExecutable,
          args: const [],
        ),
      );

      await b.disable();

      expect(
        file.existsSync(),
        isTrue,
        reason: 'the second guard must refuse a plist that became foreign',
      );
      expect(
        parseLaunchAgentPlist(file.readAsStringSync()).label,
        'com.vendorx.updater',
      );
    });

    test('still removes an agent rewritten under our own label', () async {
      // The other half of the guard above, and the reason it falls back to a
      // label check rather than refusing on any byte difference: a concurrent
      // enable() rewrites the file with the same Label. Refusing that would
      // leave our own registration in place while disable() reported success.
      final launchctl = FakeLaunchctl();
      final b = backend(launchctl: launchctl);
      await b.enable();

      final file = plistFile('dev.justautostart.test');
      launchctl.onBootout = () => file.writeAsStringSync(
        generateLaunchAgentPlist(
          label: 'dev.justautostart.test',
          executablePath: realExecutable,
          args: const ['--rewritten'],
        ),
      );

      await b.disable();

      expect(file.existsSync(), isFalse);
    });

    test('boots out even when immediate activation was not asked for', () async {
      // `activateImmediately` describes the backend instance, not the
      // registration. An application that enabled with it and disables through
      // a default-constructed backend would otherwise delete the plist while
      // the job stayed loaded, with nothing able to unload it by name until the
      // next login — the harm the bootout-before-delete order exists to
      // prevent.
      final launchctl = FakeLaunchctl()..loaded = true;
      final b = backend(launchctl: launchctl);
      await b.enable();

      await b.disable();

      expect(launchctl.sessionCalls, ['bootout:dev.justautostart.test']);
      expect(launchctl.loaded, isFalse);
    });

    test('leaves a FIFO at our path alone instead of blocking on it', () async {
      // existsSync() is true for a FIFO, and readAsStringSync on one blocks
      // until a writer appears — which may be never. Reproduced on macOS 14.5
      // (#22), and it sits inside the window guarding an irreversible unlink.
      //
      // Run in a child process, because the block is *synchronous*: it freezes
      // the isolate, so an in-process `Future.timeout` never gets scheduled to
      // fire and the defect would hang this suite instead of failing it.
      // Removing the regular-file guard and running this test is what
      // established that — see disable_fifo_probe.dart.
      const label = 'dev.justautostart.fifo';
      final path = plistFile(label).path;
      expect(Process.runSync('mkfifo', [path]).exitCode, 0);
      addTearDown(() => Process.runSync('rm', ['-f', path]));

      final probe = await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/macos/disable_fifo_probe.dart',
        scratch.path,
        label,
        'disable',
      ]);
      addTearDown(probe.kill);

      final exitCode = await probe.exitCode.timeout(
        // Under the runner's own 30 s per-test timeout, so a hang fails here
        // with the reason below rather than as an anonymous runner timeout.
        const Duration(seconds: 15),
        onTimeout: () {
          probe.kill();
          return -1;
        },
      );

      expect(
        exitCode,
        0,
        reason: 'disable() must return rather than block on a FIFO',
      );
      expect(
        FileSystemEntity.typeSync(path),
        FileSystemEntityType.pipe,
        reason: 'a FIFO is not a registration and must be left in place',
      );
    });

    test('is silent when the plist vanishes during the bootout', () async {
      // Two concurrent disable() calls, or a user deleting the file by hand
      // mid-operation. What this pins is the *guard's* tolerance: the file is
      // gone by the time the second guard reads it, so disable() returns there
      // and never reaches the delete.
      //
      // It does **not** cover the delete's own ENOENT branch, which needs the
      // file to vanish in the ~50 µs after the guard — a window with no seam in
      // it by design. Making that branch fatal leaves this test green; the
      // backend's comment on it says so rather than claiming a coverage this
      // fixture cannot deliver (`lessons.md` #24).
      final launchctl = FakeLaunchctl();
      final b = backend(launchctl: launchctl);
      await b.enable();

      final file = plistFile('dev.justautostart.test');
      launchctl.onBootout = file.deleteSync;

      await b.disable();

      expect(file.existsSync(), isFalse);
    });

    test(
      'raises a typed failure for a plist it cannot read',
      () async {
        // Not "not ours": an unreadable file at this application's own label is a
        // registration that would be left in place while disable() reported
        // success — the swallowed-failure defect this package refuses. It must
        // also not escape as a raw dart:io FileSystemException, which is outside
        // the sealed hierarchy a caller switches over.
        final file = plistFile('dev.justautostart.test');
        await backend().enable();
        expect(Process.runSync('chmod', ['000', file.path]).exitCode, 0);
        addTearDown(() => Process.runSync('chmod', ['644', file.path]));

        await expectLater(
          backend().disable(),
          throwsA(
            isA<AutostartOsException>().having(
              (e) => e.errorCode,
              'errorCode',
              13,
            ),
          ),
        );
        expect(file.existsSync(), isTrue);
      },
      skip: Platform.environment['USER'] == 'root'
          ? 'root reads a 0000 file regardless of its mode'
          : null,
    );
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

    test(
      'raises a typed failure for a plist it cannot read',
      () async {
        // Distinct from the corrupt case above: this one never gets as far as the
        // parser. Before #22 it escaped as a raw dart:io PathAccessException,
        // outside the sealed hierarchy `AutostartException` exists to let a caller
        // switch over — and reporting it as a plain `false` would be worse still,
        // since the registration is there and would launch.
        final file = plistFile('dev.justautostart.test');
        await backend().enable();
        expect(Process.runSync('chmod', ['000', file.path]).exitCode, 0);
        addTearDown(() => Process.runSync('chmod', ['644', file.path]));

        await expectLater(
          backend().isEnabled(),
          throwsA(
            isA<AutostartOsException>().having(
              (e) => e.errorCode,
              'errorCode',
              13,
            ),
          ),
        );
      },
      skip: Platform.environment['USER'] == 'root'
          ? 'root reads a 0000 file regardless of its mode'
          : null,
    );

    test('is false for a FIFO at our path, without blocking on it', () async {
      // isEnabled() is the method this package's own documentation points
      // callers at for rendering a settings toggle, so a path that can hang it
      // hangs the caller's UI. Measured hanging before #22 shared disable()'s
      // reader. Run in a child process for the same reason as the disable case:
      // the block is synchronous, so an in-process timeout cannot fire.
      const label = 'dev.justautostart.fifo';
      final path = plistFile(label).path;
      expect(Process.runSync('mkfifo', [path]).exitCode, 0);
      addTearDown(() => Process.runSync('rm', ['-f', path]));

      final probe = await Process.start(Platform.resolvedExecutable, [
        'run',
        'test/macos/disable_fifo_probe.dart',
        scratch.path,
        label,
        'isEnabled',
      ]);
      addTearDown(probe.kill);

      final exitCode = await probe.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          probe.kill();
          return -1;
        },
      );

      expect(
        exitCode,
        0,
        reason: exitCode == 2
            ? 'a FIFO is not a registration; isEnabled() must be false'
            : 'isEnabled() must return rather than block on a FIFO',
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

  group('immediate activation', () {
    const label = 'dev.justautostart.test';

    MacosAutostartBackend activating(FakeLaunchctl launchctl) =>
        MacosAutostartBackend(
          config: config(),
          launchAgentsDirectory: scratch,
          launchctl: launchctl,
          options: const MacosAutostartOptions(activateImmediately: true),
        );

    test('enable bootstraps the agent into the current session', () async {
      final launchctl = FakeLaunchctl();
      final b = activating(launchctl);

      await b.enable();

      expect(
        launchctl.sessionCalls,
        contains('bootstrap:${plistFile(label).path}'),
      );
      expect(await b.isRunningNow(), isTrue);
    });

    test('enable does not touch the session without the option', () async {
      final launchctl = FakeLaunchctl();

      await backend(launchctl: launchctl).enable();

      expect(launchctl.sessionCalls, isEmpty);
    });

    test('a failed bootstrap does not throw, and is reported', () async {
      // The plist is written and the agent will start at the next login, so a
      // failure to start it *now* is a partial success, not an error. Turning
      // it into an exception would tell the caller something false.
      final launchctl = FakeLaunchctl()..bootstrapSucceeds = false;
      final b = activating(launchctl);

      await b.enable();

      expect(plistFile(label).existsSync(), isTrue);
      expect(await b.isEnabled(), isTrue);
      // ...but the caller can still find out that it is not running yet.
      expect(await b.isRunningNow(), isFalse);
    });

    test('enabling twice reloads rather than failing', () async {
      // Measured: `launchctl bootstrap` on an already-loaded agent fails, so a
      // second enable() has to boot the old job out first. That also makes a
      // changed configuration take effect, instead of leaving the previously
      // loaded job running.
      final launchctl = FakeLaunchctl();
      final b = activating(launchctl);

      await b.enable();
      launchctl.sessionCalls.clear();
      await b.enable();

      expect(launchctl.sessionCalls, [
        'bootout:$label',
        'bootstrap:${plistFile(label).path}',
      ]);
      expect(await b.isRunningNow(), isTrue);
    });

    test('disable boots the agent out before deleting the plist', () async {
      // Order matters: `launchctl bootout` names a job launchd resolved from
      // the file, so removing the file first would leave the job loaded with
      // nothing to unload it by.
      final launchctl = FakeLaunchctl();
      final b = activating(launchctl);
      await b.enable();

      var plistExistedAtBootout = false;
      launchctl.onBootout = () {
        plistExistedAtBootout = plistFile(label).existsSync();
      };

      await b.disable();

      expect(plistExistedAtBootout, isTrue);
      expect(plistFile(label).existsSync(), isFalse);
      expect(await b.isRunningNow(), isFalse);
    });

    test('disable is still a no-op when nothing is loaded', () async {
      // Measured: booting out an agent that is not loaded fails with "No such
      // process". That is the ordinary repeat-disable path, not an error.
      final launchctl = FakeLaunchctl();
      final b = activating(launchctl);

      await b.disable();

      expect(launchctl.sessionCalls, isEmpty);
    });

    test('disable leaves a foreign agent, and its session, alone', () async {
      // The ownership guard governs the session command too: booting out a
      // label we do not own would stop a third party's running agent.
      final launchctl = FakeLaunchctl()..loaded = true;
      plistFile(label).writeAsStringSync(
        generateLaunchAgentPlist(
          label: 'com.vendorx.updater',
          executablePath: realExecutable,
          args: const [],
        ),
      );

      await activating(launchctl).disable();

      expect(launchctl.sessionCalls, isEmpty);
      expect(plistFile(label).existsSync(), isTrue);
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

    test('a bootstrap that cannot succeed reports false, never throws', () {
      // The failed-activation path against the real command. A plist that is
      // not there cannot be loaded, and `launchctl` says so by failing rather
      // than by crashing us.
      expect(
        const SystemLaunchctl().bootstrap('/no/such/agent.plist'),
        isFalse,
      );
    });

    test('repeated reads stay consistent once the domain is memoised', () {
      // The uid is resolved once per process and remembered. What a test can
      // honestly pin is that the memo did not change the answer — that the
      // second and third reads still reach the same launchd domain as the
      // first. The saving itself is a timing property, proved by the
      // before/after measurement recorded in issue #14, not by an assertion
      // here: a timing assertion on a shared CI machine is a flake, not a test.
      const launchctl = SystemLaunchctl();

      final first = launchctl.readDisabledOverrides();
      final second = launchctl.readDisabledOverrides();
      final third = const SystemLaunchctl().readDisabledOverrides();

      // Either all null (no GUI domain) or all real reads — never a mix, which
      // is what a memo that cached a failure would produce.
      expect(second == null, first == null);
      expect(third == null, first == null);
      if (first != null) {
        expect(second, contains('disabled services'));
        expect(third, contains('disabled services'));
      }
    });

    test('isLoaded is false for a label nothing registered', () {
      expect(
        const SystemLaunchctl().isLoaded('dev.justautostart.never.registered'),
        isFalse,
      );
    });

    test('activates and deactivates a real agent in this session', () async {
      // The one test that drives the real session. `/usr/bin/true` exits
      // immediately and takes no arguments, so loading it starts nothing that
      // outlives the test; the plist lives in the scratch directory; and the
      // agent is booted out again below — and once more in tearDown, so a
      // failure part-way through still leaves no session registration behind.
      const activationLabel = 'dev.justautostart.activation.test';
      final b = MacosAutostartBackend(
        config: AutostartConfig(
          appName: 'JustAutostartActivationTest',
          label: activationLabel,
          executablePath: '/usr/bin/true',
        ),
        launchAgentsDirectory: scratch,
        options: const MacosAutostartOptions(activateImmediately: true),
      );

      addTearDown(() => const SystemLaunchctl().bootout(activationLabel));

      await b.enable();

      // On a runner with no GUI domain the bootstrap cannot work, and the
      // contract is that this is still not a failure — the agent is registered
      // and starts at the next login. Assert whichever of the two holds, and
      // that `enable()` did not throw either way.
      expect(
        File('${scratch.path}/$activationLabel.plist').existsSync(),
        isTrue,
      );
      final runningInSession = await b.isRunningNow();

      await b.disable();

      expect(await b.isRunningNow(), isFalse);
      expect(
        File('${scratch.path}/$activationLabel.plist').existsSync(),
        isFalse,
      );
      // Recorded rather than asserted: which branch the machine took.
      printOnFailure('bootstrapped into this session: $runningInSession');
    });
  });
}
