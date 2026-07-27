@TestOn('windows')
library;

import 'dart:io';

import 'package:just_autostart/src/backends/windows/current_user.dart';
import 'package:test/test.dart';

void main() {
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
