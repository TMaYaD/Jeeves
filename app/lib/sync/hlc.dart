/// Hybrid logical clocks — the only ordering the reducer trusts.
///
/// The server's `seq` is a transport cursor and nothing else (review F20).
/// Merge order comes from here: `(wall_ms, counter, member_id)`, compared as a
/// tuple in that order.
library;

import 'envelope.dart';

/// A member id inside an HLC is exactly 32 lowercase hex characters — the
/// 16-byte member UUID with no dashes. The tie-break is a lexicographic string
/// compare, so casing and dashes are semantics, not style: this is validated,
/// never normalised.
final RegExp memberIdHexPattern = RegExp(r'^[0-9a-f]{32}$');

String memberIdToHex(String memberUuid) =>
    memberUuid.replaceAll('-', '').toLowerCase();

/// `(wall_ms, counter, member_id)`.
class Hlc implements Comparable<Hlc> {
  Hlc(this.wallMs, this.counter, this.memberIdHex) {
    if (!memberIdHexPattern.hasMatch(memberIdHex)) {
      throw SyncRejection(
        SyncRejectionReason.malformedMemberIdHex,
        'member id "$memberIdHex" is not 32 lowercase hex characters',
      );
    }
  }

  factory Hlc.forMember(String memberUuid, int wallMs, [int counter = 0]) =>
      Hlc(wallMs, counter, memberIdToHex(memberUuid));

  factory Hlc.fromJson(Object? raw) {
    if (raw is! List || raw.length != 3) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPayload,
        'hlc must be a 3-element array',
      );
    }
    final wallMs = raw[0];
    final counter = raw[1];
    final memberIdHex = raw[2];
    if (wallMs is! int || counter is! int) {
      throw const SyncRejection(
        SyncRejectionReason.malformedPayload,
        'hlc wall_ms and counter must be integers',
      );
    }
    if (memberIdHex is! String) {
      throw const SyncRejection(
        SyncRejectionReason.malformedMemberIdHex,
        'hlc member id must be a string',
      );
    }
    return Hlc(wallMs, counter, memberIdHex);
  }

  final int wallMs;
  final int counter;
  final String memberIdHex;

  List<Object> toJson() => [wallMs, counter, memberIdHex];

  @override
  int compareTo(Hlc other) {
    final byWall = wallMs.compareTo(other.wallMs);
    if (byWall != 0) return byWall;
    final byCounter = counter.compareTo(other.counter);
    if (byCounter != 0) return byCounter;
    return memberIdHex.compareTo(other.memberIdHex);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;

  bool operator <(Hlc other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.wallMs == wallMs &&
      other.counter == counter &&
      other.memberIdHex == memberIdHex;

  @override
  int get hashCode => Object.hash(wallMs, counter, memberIdHex);

  @override
  String toString() => 'Hlc($wallMs, $counter, $memberIdHex)';
}

/// The classic hybrid logical clock, with an injectable wall clock so the
/// multi-device harness can run on a fake one and produce genuinely concurrent
/// writes instead of racing real time.
class HlcClock {
  HlcClock({required this.memberIdHex, required int Function() nowMs})
      : _nowMs = nowMs;

  final String memberIdHex;
  final int Function() _nowMs;

  int _lastWallMs = 0;
  int _counter = 0;

  /// The clock for a local write.
  Hlc send() {
    final now = _nowMs();
    if (now > _lastWallMs) {
      _lastWallMs = now;
      _counter = 0;
    } else {
      _counter += 1;
    }
    return Hlc(_lastWallMs, _counter, memberIdHex);
  }

  /// Merge a remote clock in, so the next local write sorts after it.
  void receive(Hlc remote) {
    final now = _nowMs();
    final merged = [_lastWallMs, remote.wallMs, now].reduce((a, b) => a > b ? a : b);
    if (merged == _lastWallMs && merged == remote.wallMs) {
      _counter = (_counter > remote.counter ? _counter : remote.counter) + 1;
    } else if (merged == _lastWallMs) {
      _counter += 1;
    } else if (merged == remote.wallMs) {
      _counter = remote.counter + 1;
    } else {
      _counter = 0;
    }
    _lastWallMs = merged;
  }
}
