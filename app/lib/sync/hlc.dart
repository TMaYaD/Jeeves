/// Hybrid logical clocks — the only ordering the reducer trusts.
///
/// The server's `seq` is a transport cursor and nothing else (review F20).
/// Merge order comes from here: `(wall_ms, counter, member_id)`, compared as a
/// tuple in that order.
library;

import 'sync_rejection.dart';

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

/// The mutable half of an [HlcClock], shared by every view of one clock.
class _ClockState {
  int lastWallMs = 0;
  int counter = 0;
}

/// The classic hybrid logical clock, with an injectable wall clock so the
/// multi-device harness can run on a fake one and produce genuinely concurrent
/// writes instead of racing real time.
///
/// One device has **one** clock state. [viewFor] hands out a clock that shares
/// that state but stamps a different tie-break identity, which is how the sync
/// host (stamping with a device node id, or the member id while enrolled) and the
/// op-log client (always its member id) can both mint clocks without ever
/// issuing the same `(wall_ms, counter)` twice.
class HlcClock {
  HlcClock({required this.memberIdHex, required int Function() nowMs})
      : _nowMs = nowMs,
        _state = _ClockState();

  HlcClock._shared(this.memberIdHex, this._nowMs, this._state);

  /// The identity [send] stamps unless the caller names another.
  final String memberIdHex;
  final int Function() _nowMs;
  final _ClockState _state;

  /// A clock over the same state that stamps [memberIdHex] by default.
  HlcClock viewFor(String memberIdHex) {
    if (!memberIdHexPattern.hasMatch(memberIdHex)) {
      throw SyncRejection(
        SyncRejectionReason.malformedMemberIdHex,
        'member id "$memberIdHex" is not 32 lowercase hex characters',
      );
    }
    return HlcClock._shared(memberIdHex, _nowMs, _state);
  }

  /// The clock for a local write, stamped with [nodeIdHex] when given.
  Hlc send({String? nodeIdHex}) {
    final now = _nowMs();
    if (now > _state.lastWallMs) {
      _state.lastWallMs = now;
      _state.counter = 0;
    } else {
      _state.counter += 1;
    }
    return Hlc(_state.lastWallMs, _state.counter, nodeIdHex ?? memberIdHex);
  }

  /// Merge a remote clock in, so the next local write sorts after it.
  void receive(Hlc remote) {
    final now = _nowMs();
    final merged =
        [_state.lastWallMs, remote.wallMs, now].reduce((a, b) => a > b ? a : b);
    if (merged == _state.lastWallMs && merged == remote.wallMs) {
      _state.counter =
          (_state.counter > remote.counter ? _state.counter : remote.counter) +
              1;
    } else if (merged == _state.lastWallMs) {
      _state.counter += 1;
    } else if (merged == remote.wallMs) {
      _state.counter = remote.counter + 1;
    } else {
      _state.counter = 0;
    }
    _state.lastWallMs = merged;
  }
}
