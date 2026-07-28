/// Hybrid logical clock ordering and merge.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/sync/hlc.dart';

const String _memberA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _memberB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  group('ordering', () {
    test('compares wall_ms, then counter, then member id', () {
      expect(Hlc(2, 0, _memberA) > Hlc(1, 99, _memberB), isTrue);
      expect(Hlc(1, 1, _memberA) > Hlc(1, 0, _memberB), isTrue);
      expect(Hlc(1, 0, _memberB) > Hlc(1, 0, _memberA), isTrue);
      expect(Hlc(1, 0, _memberA) == Hlc(1, 0, _memberA), isTrue);
      expect(Hlc(1, 0, _memberA) > Hlc(1, 0, _memberA), isFalse);
    });

    test('round-trips through JSON', () {
      final clock = Hlc(1800000000000, 3, _memberA);
      expect(Hlc.fromJson(clock.toJson()), clock);
    });
  });

  group('HlcClock', () {
    test('send bumps the counter while the wall clock stands still', () {
      var now = 1000;
      final clock = HlcClock(memberIdHex: _memberA, nowMs: () => now);
      expect(clock.send(), Hlc(1000, 0, _memberA));
      expect(clock.send(), Hlc(1000, 1, _memberA));
      expect(clock.send(), Hlc(1000, 2, _memberA));
      now = 2000;
      expect(clock.send(), Hlc(2000, 0, _memberA));
    });

    test('send never goes backwards when the wall clock does', () {
      var now = 5000;
      final clock = HlcClock(memberIdHex: _memberA, nowMs: () => now);
      final first = clock.send();
      now = 1000;
      final second = clock.send();
      expect(second > first, isTrue);
      expect(second.wallMs, 5000);
    });

    test('receive makes the next local write sort after the remote one', () {
      var now = 1000;
      final clock = HlcClock(memberIdHex: _memberA, nowMs: () => now);
      final remote = Hlc(9000, 4, _memberB);
      clock.receive(remote);
      final next = clock.send();
      expect(next > remote, isTrue);
      expect(next.wallMs, 9000);
    });

    test('receive of an older remote clock does not rewind', () {
      var now = 9000;
      final clock = HlcClock(memberIdHex: _memberA, nowMs: () => now);
      final local = clock.send();
      now = 9000;
      clock.receive(Hlc(1000, 0, _memberB));
      expect(clock.send() > local, isTrue);
    });
  });
}
