import 'package:just_autostart/src/backends/macos/launchctl.dart';
import 'package:test/test.dart';

// Captured verbatim from `launchctl print-disabled gui/502` on macOS 14.5.
// The format is not a stable public contract, so it is pinned here as a fixture
// and a change surfaces as one failing parser test rather than scattered breakage.
const _realOutput = '''
	disabled services = {
		"com.apple.ManagedClientAgent.enrollagent" => disabled
		"com.apple.Siri.agent" => disabled
		"com.fortinet.forticlient.fortitray" => enabled
		"dev.justautostart.test" => disabled
	}
''';

void main() {
  group('overridesDisableLabel', () {
    test('is true for a label the user switched off', () {
      expect(
        overridesDisableLabel(_realOutput, 'dev.justautostart.test'),
        isTrue,
      );
    });

    test('is false for a label recorded as explicitly enabled', () {
      // launchctl leaves a cleared label in the list as "=> enabled" rather than
      // removing it; that is not a veto.
      expect(
        overridesDisableLabel(
          _realOutput,
          'com.fortinet.forticlient.fortitray',
        ),
        isFalse,
      );
    });

    test('is false for a label not listed at all', () {
      // The common case: an agent the user never touched has no override entry.
      expect(
        overridesDisableLabel(_realOutput, 'com.example.untouched'),
        isFalse,
      );
    });

    test('does not partial-match a label that is a prefix of another', () {
      // "com.apple.Siri" must not match "com.apple.Siri.agent" — the quote after
      // the label anchors it.
      expect(overridesDisableLabel(_realOutput, 'com.apple.Siri'), isFalse);
    });

    test('is false for empty output', () {
      expect(overridesDisableLabel('', 'dev.justautostart.test'), isFalse);
    });

    test('reads the pre-macOS-13 "=> true" form as disabled', () {
      // macOS 12 and earlier printed the veto as `=> true`/`=> false` before
      // Ventura switched to `=> disabled`/`=> enabled`. The same value that
      // means "vetoed" must be read the same way, or a real veto on an older OS
      // is silently dropped. (Sourced from the format history; not reproduced on
      // this 14.5 machine.)
      const legacy = '''
	disabled services = {
		"dev.justautostart.test" => true
		"com.example.on" => false
	}
''';
      expect(overridesDisableLabel(legacy, 'dev.justautostart.test'), isTrue);
      expect(overridesDisableLabel(legacy, 'com.example.on'), isFalse);
    });

    test('is false for output it does not recognise', () {
      // A future OS change to the format degrades to "not disabled" rather than a
      // false positive that would report a working agent as vetoed.
      expect(
        overridesDisableLabel(
          'Bootstrap failed: 5: Input/output error',
          'dev.justautostart.test',
        ),
        isFalse,
      );
    });
  });
}
