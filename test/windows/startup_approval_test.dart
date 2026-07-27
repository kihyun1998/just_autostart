import 'dart:typed_data';

import 'package:just_autostart/src/backends/windows/startup_approval.dart';
import 'package:test/test.dart';

import 'startup_approval_fixtures.dart';

final _realEnabled = realEnabledApproval();
final _realDisabled = realDisabledApproval();

void main() {
  group('enabledApprovalValue', () {
    test('is twelve bytes', () {
      expect(enabledApprovalValue(), hasLength(12));
    });

    test('matches what Windows itself stores for an enabled entry', () {
      expect(enabledApprovalValue(), _realEnabled);
    });

    test('reads back as approved', () {
      expect(isStartupApproved(enabledApprovalValue()), isTrue);
    });

    test('returns a fresh list each call', () {
      final first = enabledApprovalValue()..[0] = 0xFF;

      expect(first[0], 0xFF);
      expect(enabledApprovalValue()[0], 0x02);
    });
  });

  group('isStartupApproved', () {
    // Absent is the common case: Windows creates the entry when the user first
    // touches the toggle, so a never-touched registration has nothing here.
    test('treats an absent value as approved', () {
      expect(isStartupApproved(null), isTrue);
    });

    test('treats an empty value as approved', () {
      expect(isStartupApproved(Uint8List(0)), isTrue);
    });

    test('reads a real enabled entry as approved', () {
      expect(isStartupApproved(_realEnabled), isTrue);
    });

    test('reads a real disabled entry as not approved', () {
      expect(isStartupApproved(_realDisabled), isFalse);
    });

    // The meaning is carried by the *parity* of the first byte, not by the
    // specific values Windows happens to use.
    test('treats any even first byte as approved', () {
      for (final first in [0x00, 0x02, 0x04, 0x10, 0xFE]) {
        expect(
          isStartupApproved(Uint8List(12)..[0] = first),
          isTrue,
          reason: 'first byte 0x${first.toRadixString(16)} is even',
        );
      }
    });

    test('treats any odd first byte as not approved', () {
      for (final first in [0x01, 0x03, 0x05, 0x11, 0xFF]) {
        expect(
          isStartupApproved(Uint8List(12)..[0] = first),
          isFalse,
          reason: 'first byte 0x${first.toRadixString(16)} is odd',
        );
      }
    });

    // The timestamp is not part of the decision. An entry re-enabled by the
    // user could plausibly keep the bytes from when it was switched off, and
    // that must not read as disabled.
    test('ignores the timestamp bytes', () {
      final evenWithTimestamp = Uint8List.fromList(_realDisabled)..[0] = 0x02;

      expect(isStartupApproved(evenWithTimestamp), isTrue);
    });

    test('reads a single byte', () {
      expect(isStartupApproved(Uint8List.fromList([0x02])), isTrue);
      expect(isStartupApproved(Uint8List.fromList([0x03])), isFalse);
    });
  });
}
