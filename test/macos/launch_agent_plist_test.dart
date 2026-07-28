import 'package:just_autostart/just_autostart.dart';
import 'package:just_autostart/src/backends/macos/launch_agent_plist.dart';
import 'package:test/test.dart';

void main() {
  group('generateLaunchAgentPlist', () {
    test('names the executable as the first program argument', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
      );

      // Apple's schema: ProgramArguments[0] maps to the first argument of
      // execvp(3) — the executable itself.
      expect(xml, contains('<key>ProgramArguments</key>'));
      expect(xml, contains('<string>/usr/local/bin/tool</string>'));
      expect(xml, contains('<key>Label</key>'));
      expect(xml, contains('<string>com.example.tool</string>'));
    });

    test('sets RunAtLoad so the agent starts at login without launchctl', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
      );

      expect(xml, contains('<key>RunAtLoad</key>'));
      // The value element immediately follows the key.
      final afterKey = xml.substring(xml.indexOf('<key>RunAtLoad</key>'));
      expect(afterKey, startsWith('<key>RunAtLoad</key>\n\t<true/>'));
    });

    test('carries arguments in order, after the executable', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const ['--daemon', '--port=8080'],
      );

      final args = parseLaunchAgentPlist(xml);
      expect(args.executablePath, '/usr/local/bin/tool');
      expect(args.args, ['--daemon', '--port=8080']);
    });
  });

  group('XML escaping', () {
    test('escapes the ampersand, angle brackets in a path', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/opt/a&b/<tool>',
        args: const [],
      );

      // A raw '<' or '&' would make the plist not well-formed and launchd
      // would silently ignore it at login (lessons: a malformed plist is
      // invisible until the next login).
      expect(xml, contains('<string>/opt/a&amp;b/&lt;tool&gt;</string>'));
      expect(xml, isNot(contains('a&b')));
    });

    test('escapes special characters in an argument', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const ['--filter=a<b&c>d'],
      );

      expect(xml, contains('<string>--filter=a&lt;b&amp;c&gt;d</string>'));
    });

    test('escapes special characters in the label', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.a&b',
        executablePath: '/usr/local/bin/tool',
        args: const [],
      );

      expect(xml, contains('<string>com.example.a&amp;b</string>'));
    });
  });

  group('round trip', () {
    test('generate then parse yields the original label, path, and args', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/opt/My Tools/a&b/<tool>',
        args: const ['--flag', 'value with spaces', 'a<b>&c'],
      );

      final parsed = parseLaunchAgentPlist(xml);
      expect(parsed.label, 'com.example.tool');
      expect(parsed.executablePath, '/opt/My Tools/a&b/<tool>');
      expect(parsed.args, ['--flag', 'value with spaces', 'a<b>&c']);
    });

    test('what this package writes runs at login and is not disabled', () {
      // RunAtLoad and Disabled both govern whether launchd starts the job at
      // login, and both live inside the file. The reader must see them, or
      // isEnabled() would report on the strength of ProgramArguments alone.
      final parsed = parseLaunchAgentPlist(
        generateLaunchAgentPlist(
          label: 'com.example.tool',
          executablePath: '/usr/local/bin/tool',
          args: const [],
        ),
      );
      expect(parsed.runAtLoad, isTrue);
      expect(parsed.disabled, isFalse);
    });
  });

  group('the load-bearing keys inside the file', () {
    test('reads RunAtLoad false — the job would not start at login', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.tool</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/tool</string>
	</array>
	<key>RunAtLoad</key>
	<false/>
</dict>
</plist>
''';
      expect(parseLaunchAgentPlist(xml).runAtLoad, isFalse);
    });

    test('reads a missing RunAtLoad as false, matching launchd default', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.tool</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/tool</string>
	</array>
</dict>
</plist>
''';
      expect(parseLaunchAgentPlist(xml).runAtLoad, isFalse);
    });

    test('reads an in-plist Disabled true — launchd would skip the job', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.tool</string>
	<key>Disabled</key>
	<true/>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/tool</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
''';
      expect(parseLaunchAgentPlist(xml).disabled, isTrue);
    });

    test('resolves a duplicate key to the last, as Apple\'s parser does', () {
      // Verified against `plutil`: CFPropertyList — which is what launchd reads
      // the plist with — takes the last occurrence of a repeated key. A naive
      // migration that appends a new block before </dict> without removing the
      // old one produces exactly this, and isEnabled() must agree with what
      // launchd will actually run, not with the stale first block.
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.first.label</string>
	<key>Label</key>
	<string>com.last.label</string>
	<key>ProgramArguments</key>
	<array><string>/old/tool</string></array>
	<key>ProgramArguments</key>
	<array><string>/new/tool</string></array>
	<key>RunAtLoad</key>
	<true/>
	<key>RunAtLoad</key>
	<false/>
</dict>
</plist>
''';
      final parsed = parseLaunchAgentPlist(xml);
      expect(parsed.label, 'com.last.label');
      expect(parsed.executablePath, '/new/tool');
      expect(parsed.runAtLoad, isFalse);
    });

    test('a comment is not mistaken for the real value', () {
      // The parser advertises tolerance of hand-edited plists. A commented-out
      // ProgramArguments before the real one must not be the one read.
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.tool</string>
	<!-- <key>ProgramArguments</key><array><string>/old/tool</string></array> -->
	<key>ProgramArguments</key>
	<array>
		<string>/new/tool</string>
	</array>
</dict>
</plist>
''';
      expect(parseLaunchAgentPlist(xml).executablePath, '/new/tool');
    });
  });

  group('optional keys', () {
    String minimal() => generateLaunchAgentPlist(
      label: 'com.example.tool',
      executablePath: '/usr/local/bin/tool',
      args: const [],
    );

    test('the minimal plist carries none of them', () {
      // The contract from the previous ticket: a caller who configures nothing
      // gets the same minimal agent as before. Every optional key is absent,
      // not present-and-defaulted, so launchd applies its own defaults.
      final xml = minimal();

      expect(xml, isNot(contains('KeepAlive')));
      expect(xml, isNot(contains('StandardOutPath')));
      expect(xml, isNot(contains('StandardErrorPath')));
      expect(xml, isNot(contains('WorkingDirectory')));
      expect(xml, isNot(contains('EnvironmentVariables')));
    });

    test('KeepAlive appears only when asked for', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
        keepAlive: true,
      );

      expect(xml, contains('<key>KeepAlive</key>'));
      final afterKey = xml.substring(xml.indexOf('<key>KeepAlive</key>'));
      expect(afterKey, startsWith('<key>KeepAlive</key>\n\t<true/>'));
    });

    test('keepAlive: false is still written, so it is not the absent case', () {
      // Absent means "launchd's default"; an explicit false is the caller
      // saying so. They are different states and the plist distinguishes them.
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
        keepAlive: false,
      );

      final afterKey = xml.substring(xml.indexOf('<key>KeepAlive</key>'));
      expect(afterKey, startsWith('<key>KeepAlive</key>\n\t<false/>'));
    });

    test('StandardOutPath appears only when asked for', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
        standardOutPath: '/tmp/out & log.txt',
      );

      expect(
        xml,
        contains(
          '<key>StandardOutPath</key>\n\t<string>/tmp/out &amp; log.txt</string>',
        ),
      );
    });

    test('StandardErrorPath appears only when asked for', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
        standardErrorPath: '/tmp/err.txt',
      );

      expect(
        xml,
        contains(
          '<key>StandardErrorPath</key>\n\t<string>/tmp/err.txt</string>',
        ),
      );
    });

    test('WorkingDirectory appears only when asked for', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
        workingDirectory: '/opt/a&b',
      );

      expect(
        xml,
        contains(
          '<key>WorkingDirectory</key>\n\t<string>/opt/a&amp;b</string>',
        ),
      );
    });

    test('EnvironmentVariables is a dict of the pairs given', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
        environment: const {'MODE': 'daemon', 'PATH_X': '/a&b'},
      );

      expect(xml, contains('<key>EnvironmentVariables</key>'));
      expect(xml, contains('<key>MODE</key>'));
      expect(xml, contains('<string>daemon</string>'));
      // Keys and values are both escaped — a variable's value is caller data.
      expect(xml, contains('<string>/a&amp;b</string>'));
    });

    test('an empty environment map writes no EnvironmentVariables key', () {
      // An empty dict would be a meaningless key; absent is the honest form.
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
        environment: const {},
      );

      expect(xml, isNot(contains('EnvironmentVariables')));
    });

    test('every optional key together still parses back to the original', () {
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const ['--daemon', 'a<b>&c'],
        keepAlive: true,
        standardOutPath: '/tmp/out.log',
        standardErrorPath: '/tmp/err.log',
        workingDirectory: '/opt/My Tools',
        environment: const {'MODE': 'daemon'},
      );

      final parsed = parseLaunchAgentPlist(xml);
      expect(parsed.label, 'com.example.tool');
      expect(parsed.executablePath, '/usr/local/bin/tool');
      expect(parsed.args, ['--daemon', 'a<b>&c']);
      expect(parsed.runAtLoad, isTrue);
      expect(parsed.keepAlive, isTrue);
      expect(parsed.standardOutPath, '/tmp/out.log');
      expect(parsed.standardErrorPath, '/tmp/err.log');
      expect(parsed.workingDirectory, '/opt/My Tools');
      expect(parsed.environment, {'MODE': 'daemon'});
    });

    test('an environment variable cannot shadow a top-level key', () {
      // The dict of environment variables holds caller-supplied *names*, and
      // those names are `<key>` elements too. A parser that scans the whole
      // document would read `EnvironmentVariables/Label` as the agent's Label —
      // and `disable()` decides whether a plist is ours by that value, so a
      // foreign agent carrying such a variable could be deleted. Nested keys
      // are not top-level keys.
      final xml = generateLaunchAgentPlist(
        label: 'com.example.tool',
        executablePath: '/usr/local/bin/tool',
        args: const [],
        standardOutPath: '/real/out.log',
        workingDirectory: '/real/cwd',
        keepAlive: true,
        environment: const {
          'Label': 'com.attacker.tool',
          'StandardOutPath': '/evil/out.log',
          'WorkingDirectory': '/evil/cwd',
          'KeepAlive': 'nonsense',
          'RunAtLoad': 'nonsense',
        },
      );

      final parsed = parseLaunchAgentPlist(xml);
      expect(parsed.label, 'com.example.tool');
      expect(parsed.standardOutPath, '/real/out.log');
      expect(parsed.workingDirectory, '/real/cwd');
      expect(parsed.keepAlive, isTrue);
      expect(parsed.runAtLoad, isTrue);
      // The variables themselves still round-trip.
      expect(parsed.environment['Label'], 'com.attacker.tool');
    });

    test('a minimal plist parses back with the optional values absent', () {
      final parsed = parseLaunchAgentPlist(minimal());

      expect(parsed.keepAlive, isNull);
      expect(parsed.standardOutPath, isNull);
      expect(parsed.standardErrorPath, isNull);
      expect(parsed.workingDirectory, isNull);
      expect(parsed.environment, isEmpty);
    });
  });

  group('parseLaunchAgentPlist tolerance', () {
    test('ignores keys this package does not write', () {
      // A plist written by an earlier version, or by hand, may carry keys the
      // reader does not know. Rejecting it would destroy a working agent on an
      // upgrade; the contract is to ignore the unknowns.
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.tool</string>
	<key>KeepAlive</key>
	<true/>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/local/bin/tool</string>
		<string>--daemon</string>
	</array>
	<key>StandardOutPath</key>
	<string>/tmp/tool.log</string>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
''';

      final parsed = parseLaunchAgentPlist(xml);
      expect(parsed.label, 'com.example.tool');
      expect(parsed.executablePath, '/usr/local/bin/tool');
      expect(parsed.args, ['--daemon']);
    });

    test('tolerates hand-authored whitespace and attribute quoting', () {
      const xml = '''
<?xml version='1.0' encoding='UTF-8'?>
<plist version="1.0"><dict>
  <key>Label</key>   <string>com.example.tool</string>
  <key>ProgramArguments</key>
  <array>
      <string>/usr/local/bin/tool</string>
  </array>
</dict></plist>
''';

      final parsed = parseLaunchAgentPlist(xml);
      expect(parsed.label, 'com.example.tool');
      expect(parsed.executablePath, '/usr/local/bin/tool');
      expect(parsed.args, isEmpty);
    });
  });

  group('parseLaunchAgentPlist rejection', () {
    test('throws on XML that is not well-formed', () {
      expect(
        () => parseLaunchAgentPlist('<plist><dict><key>Label</key'),
        throwsA(isA<MalformedRegistrationException>()),
      );
    });

    test('throws when ProgramArguments is absent', () {
      // Without a program there is no executable to compare against; this is a
      // corrupt registration, not a foreign one, because it sits at our own
      // label's path.
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.tool</string>
</dict>
</plist>
''';
      expect(
        () => parseLaunchAgentPlist(xml),
        throwsA(isA<MalformedRegistrationException>()),
      );
    });

    test('throws when ProgramArguments is empty', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.example.tool</string>
	<key>ProgramArguments</key>
	<array>
	</array>
</dict>
</plist>
''';
      expect(
        () => parseLaunchAgentPlist(xml),
        throwsA(isA<MalformedRegistrationException>()),
      );
    });
  });
}
