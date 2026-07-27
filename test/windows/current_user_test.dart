@TestOn('windows')
library;

import 'dart:io';

import 'package:just_autostart/src/backends/windows/current_user.dart';
import 'package:test/test.dart';

void main() {
  _identityTests();

  group('currentUserSid', () {
    // The shape is checked here; the *value* is checked against Windows below.
    // A well-formed SID that belongs to somebody else would satisfy this alone.
    test('is a string SID', () {
      expect(currentUserSid(), matches(RegExp(r'^S-1-\d+(-\d+)+$')));
    });

    // `whoami /user` asks Windows the same question through a different tool.
    // Our own two calls agreeing with each other would prove nothing about
    // whose token was read.
    test('is the SID Windows reports for this user', () {
      final output =
          Process.runSync('whoami', ['/user', '/fo', 'csv', '/nh']).stdout
              as String;
      final theirs = RegExp(r'S-1-[\d-]+').firstMatch(output)?.group(0);

      expect(theirs, isNotNull, reason: 'whoami should have reported a SID');
      expect(currentUserSid(), theirs);
    });

    // A SID is variable-length, so the size negotiation runs on every call and
    // a mistake in it would show up as a truncated or corrupted second read
    // rather than as a failure.
    test('is stable across calls', () {
      expect(currentUserSid(), currentUserSid());
    });

    // The token handle and the `LocalAlloc`ed string are both released by hand.
    // Neither leak announces itself, so this at least exercises the paths often
    // enough that a handle leak would exhaust something.
    test('does not run out of handles', () {
      final first = currentUserSid();

      for (var i = 0; i < 2000; i++) {
        expect(currentUserSid(), first);
      }
    });
  });
}

// Windows hands the same identity back in more than one form. A scheduled
// task's principal is stored as a SID and read back as an account name, so a
// guard built on string equality against the SID never matches — and one built
// on the name has to guess which of several spellings it was given.
void _identityTests() {
  group('isCurrentUser', () {
    test('accepts the SID form', () {
      expect(isCurrentUser(currentUserSid()), isTrue);
    });

    test('accepts the SID whatever its case', () {
      expect(isCurrentUser(currentUserSid().toLowerCase()), isTrue);
    });

    // The form `IPrincipal::get_UserId` actually returns.
    test('accepts the bare account name', () {
      final name = (Process.runSync('whoami', const []).stdout as String)
          .trim()
          .split(r'\')
          .last;

      expect(isCurrentUser(name), isTrue);
    });

    test(r'accepts the DOMAIN\Name form', () {
      final whoami = (Process.runSync('whoami', const []).stdout as String)
          .trim();

      expect(isCurrentUser(whoami), isTrue);
    });

    // `S-1-5-18` is SYSTEM and `S-1-5-19` is LOCAL SERVICE — well-known
    // accounts that exist on every machine and are never the caller.
    test('rejects another account', () {
      expect(isCurrentUser('S-1-5-18'), isFalse);
      expect(isCurrentUser('S-1-5-19'), isFalse);
      expect(isCurrentUser('SYSTEM'), isFalse);
    });

    // An account that resolves to nobody is not this user, which is the only
    // question being asked — so it answers rather than raising.
    test('rejects a name that resolves to nobody', () {
      expect(isCurrentUser('no-such-account-qqzz'), isFalse);
      expect(isCurrentUser(''), isFalse);
      expect(isCurrentUser('S-1-5-21-0-0-0-9999'), isFalse);
    });

    test('does not run out of handles', () {
      for (var i = 0; i < 500; i++) {
        expect(isCurrentUser(currentUserSid()), isTrue);
      }
    });
  });
}
