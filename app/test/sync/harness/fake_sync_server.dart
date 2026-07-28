/// An in-process stand-in for `backend/app/sync/routes.py`.
///
/// It exists so N simulated devices can converge in a `flutter test` run with
/// no server, no network and no clock — the coverage gap ADR-0026 set out to
/// close. It is only worth anything if it behaves like the real server, so
/// `test/sync/fake_sync_server_contract_test.dart` mirrors
/// `backend/tests/sync/test_ops_routes.py`,
/// `test_recovery_escrow_routes.py` and `test_member_auth_routes.py`
/// case-for-case, and both sides load the same golden vectors.
///
/// Content-blind for content ops, exactly like the real one. Control ops are
/// the same deliberate exception: `op_class = 2` bodies *are* read, because
/// membership has to be checkable before it is materialised (ADR-0028, F2).
///
/// Two sessions, two credentials, mirroring the real split: [connectAsUser]
/// gives the User surface, [connectAsMember] the member-scoped one. There is no
/// object here that offers both under one credential, because there is none
/// there. The signal socket and the `GET /w/{w}/members` read both sit on the
/// *member* session, since that is where they sit on the server — both resolve
/// through the same member-scoped path as the ops routes, so a user session
/// neither subscribes nor reads the registry.
///
/// This class doubles the **server**, not the client, so it models endpoints no
/// client calls (the registry read is one). Dropping such an endpoint is how the
/// double came to be looser than the server on the credential it requires, which
/// is exactly the divergence the contract twin exists to catch.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/signal_socket.dart';
import 'package:jeeves/sync/sync_transport.dart';

/// One appended op, plus the header fields the server indexes it by.
class StoredOp {
  StoredOp({
    required this.seq,
    required this.workspaceId,
    required this.envelope,
    required this.header,
    this.compactedBy,
  });

  final int seq;
  final String workspaceId;
  final Uint8List envelope;

  /// Null only for rows put there by [FakeSyncServer.injectUnchecked] whose
  /// bytes do not parse — a server that skips its own validations can store
  /// anything, and the client must survive being served it.
  final OpHeader? header;

  /// Set by a prune op (#555). v1 prunes are soft deletes: default pulls hide
  /// the row, nothing is removed.
  int? compactedBy;
}

class _RegisteredMember {
  _RegisteredMember(this.userId, this.record);

  final String userId;
  MemberRecord record;

  /// Stamped when a Root-signed registration for this member materialises —
  /// either its own `member_register` or the genesis that embedded it.
  bool chained = false;

  /// Materialised from the registration certificate. Null until one lands: the
  /// kind is a *signed* fact, so a shell row cannot claim one.
  String? memberKind;
}

/// One materialised Grant — the fake's mirror of the server's own index.
///
/// Authoritative for nobody (ADR-0028). Clients derive their grants view from the
/// signed control ops in the log, which is what makes tampering with this inert.
class _StoredGrant {
  _StoredGrant({
    required this.grantId,
    required this.memberId,
    required this.role,
    required this.granter,
    required this.grantedSeq,
  });

  final String grantId;
  final String memberId;

  /// Mutable so a hostility hook can flip it — proving a client's verdict does
  /// not move when the server's index lies.
  String role;
  final String granter;
  final int grantedSeq;
  int? revokedBySeq;
}

/// The grants index for one Workspace, walked forward in batch order.
///
/// The server materialises a batch's control ops in the order they arrive, so a
/// Grant authored at index 1 counts for a content op at index 2 of the same POST.
class _GrantIndex {
  _GrantIndex(this._states);

  final Map<String, _StoredGrant> _states;

  _StoredGrant? state(String grantId) => _states[grantId];

  Iterable<_StoredGrant> _of(String memberId) =>
      _states.values.where((grant) => grant.memberId == memberId);

  Set<String> liveRoles(String memberId) => {
        for (final grant in _of(memberId))
          if (grant.revokedBySeq == null) grant.role,
      };

  bool hasAnyGrant(String memberId) => _of(memberId).isNotEmpty;

  void add(String grantId, String memberId, String role) {
    _states[grantId] = _StoredGrant(
      grantId: grantId,
      memberId: memberId,
      role: role,
      granter: granterRoot,
      grantedSeq: 0,
    );
  }

  void revoke(String grantId) => _states[grantId]?.revokedBySeq = 0;
}

/// One live signal socket, server side: who it speaks for, and how to end it.
class _SignalSubscriber {
  _SignalSubscriber({
    required this.memberId,
    required this.send,
    required this.close,
  });

  final String memberId;
  final void Function(String frame) send;
  final void Function(Object error) close;
}

/// One verified control op, and what it will materialise once it has a seq.
class _ControlAdmission {
  _ControlAdmission({
    required this.index,
    required this.controlType,
    this.registration,
    this.grant,
    this.revoke,
  });

  final int index;
  final String controlType;

  /// Populated by `member_register` and by the registration a genesis embeds.
  final RegistrationCertificate? registration;
  final GrantCertificate? grant;
  final RevokeCertificate? revoke;
}

class _EscrowSlot {
  _EscrowSlot(this.record);

  RecoveryEscrowRecord record;
}

/// Guards the single-transaction batch, mirroring `MAX_OPS_PER_BATCH`.
const int fakeServerMaxOpsPerBatch = 1000;

/// Mirrors `RECOVERY_FETCH_DAILY_LIMIT`.
const int fakeServerRecoveryFetchLimit = 20;

/// Mirrors the window the real counter expires with.
const int fakeServerRecoveryFetchWindowSeconds = 86400;

/// Mirrors `Settings.member_challenge_daily_limit`.
const int fakeServerMemberChallengeLimit = 120;

/// Mirrors `Settings.member_challenge_window_seconds`.
const int fakeServerMemberChallengeWindowSeconds = 86400;

class FakeSyncServer {
  final List<StoredOp> _log = [];
  final Map<String, _RegisteredMember> _members = {};
  final Map<String, _EscrowSlot> _escrows = {};
  final Map<String, int> _escrowFetchCounts = {};
  final Map<String, String> _challenges = {};
  final Map<String, int> _challengeCounts = {};

  /// `workspace_id -> genesis seq`. A Workspace exists once its genesis lands.
  final Map<String, int> _workspaces = {};

  /// `workspace_id -> grant_id -> grant`. The server's own authz index.
  final Map<String, Map<String, _StoredGrant>> _grants = {};

  /// Member ids whose transport credential a revocation killed, in order — the
  /// fake's stand-in for `revoke_member_transport`.
  final List<String> revokedTransports = [];
  int _nextSeq = 1;

  /// Dart mirror of `backend/app/sync/signal_hub.py`: subscribers per Workspace,
  /// each tagged with the Member it speaks for — no seqs, no cursors, no history.
  ///
  /// The member id is the only thing the hub knows beyond the Workspace, and it
  /// exists for exactly one reason: a socket is authenticated once, at the
  /// handshake, so revoking a Member's last live Grant has to be able to *close*
  /// its sockets rather than merely stop admitting new ones.
  final Map<String, List<_SignalSubscriber>> _signalSubscribers = {};

  /// Every batch the server accepted for a POST, in order — lets a test assert
  /// what actually went over the wire.
  final List<List<Uint8List>> receivedBatches = [];

  /// Every escrow read that **served bytes**, in order: the append-only audit
  /// the real server keeps, which records a read of a slot rather than a request
  /// for one. A probe against an empty slot leaves no row here because it leaves
  /// none there either — nothing left the server, and with a 404 no longer
  /// spending the daily fetch quota, auditing probes would be an unbounded
  /// audit-row mill for anyone holding a stolen User credential.
  final List<({String userId, String workspaceId})> escrowFetches = [];

  /// Every frame the signal socket put on the wire, per Workspace, in order —
  /// the same kind of recording as [receivedBatches], on the other direction.
  /// A fidelity smoke check: the binding no-payload assertion is the backend's
  /// `test_signal_socket.py`, which watches a real socket.
  final Map<String, List<String>> emittedSignalFrames = {};

  List<StoredOp> get storedOps => List.unmodifiable(_log);

  bool isChained(String memberId) => _members[memberId]?.chained ?? false;

  /// Live signal sockets on a Workspace. A client that leaks a subscription
  /// shows up here as a count that never comes back down.
  int signalSubscriberCount(String workspaceId) =>
      _signalSubscribers[workspaceId]?.length ?? 0;

  /// The User-credential surface.
  ///
  /// It takes the socket knobs without owning a socket: the member session it
  /// mints at the end of the ceremony is the one that subscribes, and this is
  /// where the harness gets to say which clock that session should run on.
  FakeSyncServerUserSession connectAsUser(
    String userId, {
    SignalTimerFactory signalTimerFactory = Timer.new,
    Duration keepaliveInterval = signalKeepaliveInterval,
  }) =>
      FakeSyncServerUserSession(
        this,
        userId,
        signalTimerFactory: signalTimerFactory,
        keepaliveInterval: keepaliveInterval,
      );

  /// The member-credential surface, as the proof-of-possession exchange would
  /// have handed it out. Tests that do not care about the ceremony take it
  /// directly; nothing in production can.
  ///
  /// The signal socket lives on *this* session and not on the User one, because
  /// on the real server it does: `WS /w/{w}/signal` resolves through the same
  /// member-scoped path as the ops routes, so a subscription is not something a
  /// user session can open.
  ///
  /// [signalTimerFactory] and [keepaliveInterval] drive the socket's keepalives
  /// off the harness's manually advanced clock, so an idle socket in a test is
  /// distinguishable from a dead one without any real waiting.
  FakeSyncServerMemberSession connectAsMember(
    String memberId, {
    SignalTimerFactory signalTimerFactory = Timer.new,
    Duration keepaliveInterval = signalKeepaliveInterval,
  }) =>
      FakeSyncServerMemberSession(
        this,
        memberId,
        signalTimerFactory: signalTimerFactory,
        keepaliveInterval: keepaliveInterval,
      );

  /// Test hook for #555's soft delete, which has no client-side emitter yet.
  void markCompacted(int seq, {required int by}) {
    _log.firstWhere((op) => op.seq == seq).compactedBy = by;
  }

  // --- Serving-side hostility ------------------------------------------------
  //
  // Fault injection lives here rather than in the client's link because the
  // faults #551 defends against are *serving* faults: a server that drops,
  // reorders, rewinds or replays. The client path stays production-real, which
  // is the only way an alarm it raises is evidence of anything.

  /// Seqs that pulls pretend do not exist — a withheld op.
  final Set<int> omitSeqs = {};

  /// Workspaces whose **next** pull serves an empty page, consumed by that pull.
  ///
  /// [omitSeqs] is a standing lie; this is one page's worth, and it exists because
  /// the losing side of a genesis race cannot be staged any other way: the whole
  /// race is that a device pulled, the log *was* empty, and by the time it posted
  /// the winner's genesis was already there. A one-shot blindfold over the pull
  /// reproduces exactly that view without needing two ceremonies to interleave.
  ///
  /// Keyed by Workspace because an enrolment pulls two of them in a fixed order,
  /// and a race is a property of one.
  final Set<String> blindNextPullOf = {};

  /// Serve a pull page in this seq order instead of ascending. Seqs the log has
  /// and this list does not keep their ascending place behind the listed ones.
  List<int>? serveOrder;

  /// Serve from seq 1 whatever `since` the client asked with. `since` is a pure
  /// client parameter, so no honest server can do this.
  bool ignoreSinceParameter = false;

  /// Forget a Workspace entirely: its log rows, its genesis, and its Grants.
  ///
  /// A **crash simulation**, not a hostility: it stands for a ceremony that wrote
  /// one Workspace's escrow slot and died before posting that Workspace's genesis.
  /// The state it produces is the one the log-state-conditioned genesis rule
  /// exists to recover from, and the only way to reach it is from outside.
  void forgetWorkspace(String workspaceId) {
    _log.removeWhere((op) => op.workspaceId == workspaceId);
    _workspaces.remove(workspaceId);
    _grants.remove(workspaceId);
  }

  /// Truncate the log above [seq] and hand the freed seqs back out.
  ///
  /// The rollback and stale-prefix stage in one hook: history the client has
  /// already seen and acknowledged simply stops existing, and the next append
  /// reuses its transport positions.
  void rollbackToSeq(int seq) {
    _log.removeWhere((op) => op.seq > seq);
    _nextSeq = seq + 1;
  }

  /// Append bytes without running any of the server's own checks.
  ///
  /// This is the *hostile or broken server*: the fail-closed rules on the
  /// client exist precisely because nothing stops a server from serving an
  /// envelope it should have refused, or one it forged. Returns the assigned
  /// seq.
  ///
  /// [atSeq] spends a transport seq the log has already spent. The seq is the
  /// server's own bookkeeping, so nothing but its honesty stops it handing one
  /// position to two different ops — and the client's log is keyed by it.
  int injectUnchecked(String workspaceId, Uint8List envelope, {int? atSeq}) {
    OpHeader? header;
    try {
      header = OpHeader.parse(envelope);
    } on SyncRejection {
      header = null;
    }
    final op = StoredOp(
      seq: atSeq ?? _nextSeq++,
      workspaceId: workspaceId,
      envelope: envelope,
      header: header,
    );
    _log.add(op);
    // A hostile server pokes about ops it should never have stored. The client
    // must survive that, and it does: a poke is only ever "go and sync".
    _notify(workspaceId);
    return op.seq;
  }

  /// Put a member row in the registry without a MemberRegister behind it.
  ///
  /// The *poisoned registry*: a server can claim anything about who its users'
  /// devices are. Chain-gating is what makes the claim inert.
  void poisonRegistry(String userId, MemberRecord record) {
    _members[record.memberId] = _RegisteredMember(userId, record);
  }

  // --- The signal socket -----------------------------------------------------

  /// Poke every subscriber of [workspaceId]. Never crosses Workspaces, and
  /// holds no memory of what any subscriber has already seen.
  void _notify(String workspaceId) {
    for (final subscriber in [...?_signalSubscribers[workspaceId]]) {
      subscriber.send('');
    }
  }

  /// Close every live socket [memberId] holds on [workspaceId], with `4403`.
  ///
  /// The same close code the handshake would have refused it with, so the
  /// client's reconnect ladder needs no new branch: it already treats 4403 as
  /// "do not retry blindly".
  void _closeSignals(String workspaceId, String memberId) {
    for (final subscriber in [...?_signalSubscribers[workspaceId]]) {
      if (subscriber.memberId != memberId) continue;
      subscriber.close(
        const SyncTransportException(
          signalCloseForbidden,
          'no live Grant (revoked)',
          code: 'no_live_grant',
        ),
      );
    }
  }

  /// The frames the signal socket puts on the wire, server side.
  ///
  /// Deliberately raw: the idle deadline and the keepalive/poke grammar are the
  /// *transport's* job on the client, so a link fault injected between the two
  /// (see `DeviceLink.goSilent`) starves the deadline exactly as a half-open
  /// socket would.
  Stream<String> _signalFrames(
    String memberId,
    String workspaceId, {
    required SignalTimerFactory timerFactory,
    required Duration keepaliveInterval,
  }) {
    final controller = StreamController<String>();
    Timer? keepalive;
    late final void Function(String) send;
    _SignalSubscriber? subscriber;

    void armKeepalive() {
      keepalive?.cancel();
      // The keepalive is the timeout branch of the same wait that delivers
      // pokes, so it only ever fires in the absence of news.
      keepalive = timerFactory(keepaliveInterval, () => send(keepaliveFrame));
    }

    send = (String frame) {
      if (controller.isClosed) return;
      (emittedSignalFrames[workspaceId] ??= []).add(frame);
      controller.add(frame);
      armKeepalive();
    };

    controller.onListen = () {
      // Member first, then the Workspace — the same order, and the same two
      // questions, as `resolve_member_token` followed by `_authorize_workspace`
      // on the real socket.
      final member = _members[memberId];
      if (member == null) {
        controller.addError(
          const SyncTransportException(
            signalCloseUnauthenticated,
            'unknown member',
            code: 'unknown_member',
          ),
        );
        unawaited(controller.close());
        return;
      }
      try {
        _authorizeWorkspace(member.userId, workspaceId);
        // Held to the member-GET bar: a pre-grant device may subscribe during
        // enrolment, and a revoked one is refused at the door as well as having
        // its live sockets closed under it.
        _refuseIfRevoked(workspaceId, memberId);
      } on SyncTransportException catch (refusal) {
        controller.addError(
          SyncTransportException(
            signalCloseForbidden,
            refusal.detail,
            // The structured code the real 403 carries. A close frame cannot
            // hold a body, so the client branches on the close code — but the
            // fake keeps the code alongside it rather than regressing to a bare
            // string, so a twin can assert the same contract on both sides.
            code: refusal.code,
          ),
        );
        unawaited(controller.close());
        return;
      }
      subscriber = _SignalSubscriber(
        memberId: memberId,
        send: send,
        close: (error) {
          if (controller.isClosed) return;
          controller.addError(error);
          keepalive?.cancel();
          _signalSubscribers[workspaceId]?.remove(subscriber);
          unawaited(controller.close());
        },
      );
      _signalSubscribers.putIfAbsent(workspaceId, () => []).add(subscriber!);
      // The initial poke is the subscribe ack *and* the catch-up trigger.
      send('');
    };
    controller.onCancel = () {
      keepalive?.cancel();
      if (subscriber != null) _signalSubscribers[workspaceId]?.remove(subscriber);
    };
    return controller.stream;
  }

  // --- The endpoints ---------------------------------------------------------

  MemberRecord _registerMember(
    String userId,
    String memberId,
    Uint8List signPk,
    Uint8List kexPk,
  ) {
    if (signPk.length != signPublicKeyBytes) {
      throw const SyncTransportException(422, 'sign_pk length', code: 'malformed_sign_pk');
    }
    if (kexPk.length != kexPublicKeyBytes) {
      throw const SyncTransportException(422, 'kex_pk length', code: 'malformed_kex_pk');
    }
    final existing = _members[memberId];
    if (existing != null) {
      if (existing.userId != userId ||
          !_sameBytes(existing.record.signPk, signPk) ||
          (existing.record.kexPk != null && !_sameBytes(existing.record.kexPk!, kexPk))) {
        throw const SyncTransportException(
          409,
          'Member id already registered with a different key',
          code: 'member_id_already_registered',
        );
      }
      return existing.record;
    }
    // Server-derived, never a client claim.
    final record = MemberRecord(
      memberId: memberId,
      signPk: signPk,
      keyId: deriveKeyId(signPk),
      kexPk: kexPk,
    );
    _members[memberId] = _RegisteredMember(userId, record);
    return record;
  }

  /// `GET /w/{w}/members`, keyed the way the real route keys it.
  ///
  /// Takes a **member** id, not a user id: the route authenticates through
  /// `get_current_member` and derives the owner from the token's Member, so a
  /// caller holding only a User credential cannot reach it. Resolving the owner
  /// here rather than accepting one is what keeps the double from being looser
  /// than the server on that point.
  List<MemberRecord> _listMembers(String memberId, String workspaceId) {
    final caller = _members[memberId];
    if (caller == null) {
      throw const SyncTransportException(401, 'unknown member', code: 'unknown_member');
    }
    final userId = caller.userId;
    _authorizeWorkspace(userId, workspaceId);
    return [
      for (final member in _members.values)
        if (member.userId == userId)
          MemberRecord(
            memberId: member.record.memberId,
            signPk: member.record.signPk,
            keyId: member.record.keyId,
            kexPk: member.record.kexPk,
            chained: member.chained,
          ),
    ];
  }

  // --- Recovery escrow -------------------------------------------------------

  static String _slot(String workspaceId, String userId) => '$workspaceId/$userId';

  Future<RecoveryEscrowRecord> _putRecoveryEscrow(
    String userId,
    String workspaceId,
    RecoveryEscrowRecord record,
  ) async {
    _authorizeWorkspace(userId, workspaceId);
    final stored = _escrows[_slot(workspaceId, userId)];
    // A 403, not a 422: the caller cannot prove control of the slot's Root, so
    // the whole request is unauthorized rather than one field invalid.
    final ok = await verifyDomainSeparated(
      escrowSigningInput(workspaceId, record.version, record.blob),
      record.rootSig,
      stored?.record.rootPk ?? record.rootPk,
    );
    if (!ok) {
      throw const SyncTransportException(
        403,
        'escrow signature does not verify',
        code: 'bad_escrow_signature',
      );
    }

    if (stored == null) {
      if (record.version != firstEscrowVersion) {
        throw const SyncTransportException(
          409,
          'stored_version 0: create must be v1',
          code: 'escrow_version_regression',
        );
      }
      _escrows[_slot(workspaceId, userId)] = _EscrowSlot(record);
      return record;
    }
    if (record.version <= stored.record.version) {
      throw SyncTransportException(
        409,
        'stored_version ${stored.record.version}',
        code: 'escrow_version_regression',
      );
    }
    // root_pk is established by the first write and never changed by a later
    // one: that is the whole point of the slot.
    stored.record = RecoveryEscrowRecord(
      version: record.version,
      blob: record.blob,
      rootSig: record.rootSig,
      rootPk: stored.record.rootPk,
    );
    return stored.record;
  }

  RecoveryEscrowRecord? _fetchRecoveryEscrow(String userId, String workspaceId) {
    _authorizeWorkspace(userId, workspaceId);
    // The existence check comes before the quota, as it does on the real server:
    // the limit bounds bytes leaving the slot, so an absent slot must not be
    // able to lock the account's real recovery fetch out for a day.
    final stored = _escrows[_slot(workspaceId, userId)];
    if (stored == null) return null;
    final count = (_escrowFetchCounts[userId] ?? 0) + 1;
    _escrowFetchCounts[userId] = count;
    if (count > fakeServerRecoveryFetchLimit) {
      throw const SyncTransportException(
        429,
        'retry_after_seconds $fakeServerRecoveryFetchWindowSeconds',
        code: 'escrow_fetch_rate_limited',
      );
    }
    escrowFetches.add((userId: userId, workspaceId: workspaceId));
    return stored.record;
  }

  // --- Member proof of possession -------------------------------------------

  int _nextNonce = 1;

  Uint8List _requestMemberChallenge(String memberId) {
    if (!_members.containsKey(memberId)) {
      throw const SyncTransportException(404, 'unknown member', code: 'unknown_member');
    }
    // The existence check comes first on purpose, exactly as it does on the real
    // route: an id-enumeration sweep must not be able to create a counter for a
    // member that was never registered.
    final count = (_challengeCounts[memberId] ?? 0) + 1;
    _challengeCounts[memberId] = count;
    if (count > fakeServerMemberChallengeLimit) {
      throw const SyncTransportException(
        429,
        'retry_after_seconds $fakeServerMemberChallengeWindowSeconds',
        code: 'member_challenge_rate_limited',
      );
    }
    // Deterministic rather than random: the harness must reproduce, and a nonce
    // only has to be unique and single-use, which a counter is.
    final nonce = Uint8List(32);
    ByteData.view(nonce.buffer).setUint32(0, _nextNonce++, Endian.big);
    _challenges[_hex(nonce)] = memberId;
    return nonce;
  }

  Future<FakeSyncServerMemberSession> _completeMemberChallenge(
    String memberId,
    Uint8List nonce,
    Uint8List signature, {
    required SignalTimerFactory signalTimerFactory,
    required Duration keepaliveInterval,
  }) async {
    const unauthorized = SyncTransportException(
      401,
      'challenge did not verify',
      code: 'bad_member_challenge',
    );
    // Spent by the attempt, win or lose: a guessing loop needs a fresh
    // round-trip for every guess.
    final claimed = _challenges.remove(_hex(nonce));
    final member = _members[memberId];
    if (claimed == null || claimed != memberId || member == null) {
      throw unauthorized;
    }
    final ok = await verifyDomainSeparated(
      domainSeparated(signingDomainAuthChallengeV1, [uuidToBytes(memberId), nonce]),
      signature,
      member.record.signPk,
    );
    if (!ok) throw unauthorized;
    return FakeSyncServerMemberSession(
      this,
      memberId,
      signalTimerFactory: signalTimerFactory,
      keepaliveInterval: keepaliveInterval,
    );
  }

  // --- Op log ----------------------------------------------------------------

  Future<List<OpAppendResult>> _postOps(
    String memberId,
    String workspaceId,
    List<Uint8List> envelopes,
  ) async {
    final member = _members[memberId];
    if (member == null) {
      throw const SyncTransportException(401, 'unknown member', code: 'unknown_member');
    }
    _authorizeWorkspace(member.userId, workspaceId);
    if (envelopes.length > fakeServerMaxOpsPerBatch) {
      throw const SyncTransportException(413, 'Batch too large', code: 'batch_too_large');
    }

    final parsed = <OpHeader>[];
    for (var index = 0; index < envelopes.length; index++) {
      final envelope = envelopes[index];
      final OpHeader header;
      try {
        header = OpHeader.parse(envelope);
        if (envelope.length < minimumEnvelopeBytes) {
          throw SyncRejection(
            SyncRejectionReason.envelopeTooShort,
            'envelope is ${envelope.length} bytes, the shortest legal one is '
            '$minimumEnvelopeBytes',
          );
        }
        header.checkServed();
      } on SyncRejection catch (rejection) {
        throw SyncTransportException(
          422,
          'ops[$index]',
          code: rejection.reason.code,
        );
      }
      if (header.workspaceId != workspaceId) {
        throw SyncTransportException(422, 'ops[$index]', code: 'workspace_mismatch');
      }
      if (header.authorMemberId != memberId) {
        // F10, in one comparison and no crypto.
        throw SyncTransportException(403, 'ops[$index]', code: 'author_member_mismatch');
      }
      parsed.add(header);
    }
    if (parsed.isEmpty) {
      receivedBatches.add(const []);
      return const [];
    }

    // Before the chain-gap check below, so a mispositioned register yields
    // `member_register_not_first` and never the 409.
    final admissions = await _verifyControlOps(member, workspaceId, envelopes, parsed);

    final lastAuthorSeq = <String, int>{};
    for (final op in _log) {
      final storedHeader = op.header;
      if (op.workspaceId != workspaceId || storedHeader == null) continue;
      final current = lastAuthorSeq[storedHeader.authorMemberId] ?? 0;
      if (storedHeader.authorSeq > current) {
        lastAuthorSeq[storedHeader.authorMemberId] = storedHeader.authorSeq;
      }
    }
    int? existingSeq(String author, String opId) {
      for (final op in _log) {
        final storedHeader = op.header;
        if (op.workspaceId == workspaceId &&
            storedHeader != null &&
            storedHeader.authorMemberId == author &&
            storedHeader.opId == opId) {
          return op.seq;
        }
      }
      return null;
    }

    // Validate the whole batch before appending any of it: a gap means the
    // author's chain is broken, and accepting the tail would make it permanent.
    final staged = <String, StoredOp>{};
    final plan = <({String opId, StoredOp? op, int? seq, bool duplicate})>[];
    for (var index = 0; index < parsed.length; index++) {
      final header = parsed[index];
      final key = '${header.authorMemberId}/${header.opId}';
      final alreadyStored = existingSeq(header.authorMemberId, header.opId);
      if (alreadyStored != null) {
        plan.add((opId: header.opId, op: null, seq: alreadyStored, duplicate: true));
        continue;
      }
      if (staged.containsKey(key)) {
        plan.add((opId: header.opId, op: staged[key], seq: null, duplicate: true));
        continue;
      }
      final expected = (lastAuthorSeq[header.authorMemberId] ?? 0) + 1;
      if (header.authorSeq != expected) {
        throw AuthorChainConflictException(
          'ops[$index]: author_seq ${header.authorSeq}, expected $expected',
          opIndex: index,
          submittedAuthorSeq: header.authorSeq,
          expectedAuthorSeq: expected,
        );
      }
      final op = StoredOp(
        seq: _nextSeq++,
        workspaceId: workspaceId,
        envelope: envelopes[index],
        header: header,
      );
      staged[key] = op;
      lastAuthorSeq[header.authorMemberId] = header.authorSeq;
      plan.add((opId: header.opId, op: op, seq: null, duplicate: false));
    }

    _log.addAll(staged.values);
    receivedBatches.add(List.unmodifiable(envelopes));
    final results = [
      for (final entry in plan)
        OpAppendResult(
          opId: entry.opId,
          seq: entry.seq ?? entry.op!.seq,
          duplicate: entry.duplicate,
        ),
    ];

    // Materialisation runs *after* the append because every index row it writes
    // is anchored to a transport seq, and a seq does not exist until the op is
    // stored. The authorization verdict is positional against those numbers, so
    // they have to be the real ones.
    for (final memberId in _materialiseControl(workspaceId, admissions, results)) {
      // Two halves of one revocation: the credential dies so nothing can
      // authenticate a *new* socket or POST, and the live sockets close so an
      // already-authenticated subscriber stops learning that activity exists.
      revokedTransports.add(memberId);
      _closeSignals(workspaceId, memberId);
    }

    if (staged.isNotEmpty) {
      // Only non-duplicate appends are news: a pure replay changes nothing, so
      // poking about it would send every subscriber on a pointless pull.
      _notify(workspaceId);
    }
    return results;
  }

  /// The control plane, dispatched per type, in the same order as the real route.
  ///
  /// Returns what each verified control op will materialise once seqs are known.
  /// Verification and materialisation are two passes for the same reason they are
  /// on the server: the first can refuse the whole batch, the second needs
  /// transport seqs that do not exist until the ops are stored.
  Future<List<_ControlAdmission>> _verifyControlOps(
    _RegisteredMember member,
    String workspaceId,
    List<Uint8List> envelopes,
    List<OpHeader> parsed,
  ) async {
    final grants = _GrantIndex(_grants[workspaceId] ?? {});
    var workspaceExists = _workspaces.containsKey(workspaceId);
    // Which of this batch's ops the log already holds. A replay must not read as
    // a *reuse* of the grant id it carries: the id belongs to the op that first
    // asserted it, and re-posting that same op asserts nothing new.
    final replayedOpIds = {
      for (final op in _log)
        if (op.workspaceId == workspaceId &&
            op.header?.authorMemberId == member.record.memberId)
          op.header!.opId,
    };
    final rootPk = _escrows[_slot(workspaceId, member.userId)]?.record.rootPk ?? Uint8List(0);
    final isPreferences = workspaceId == userPreferencesWorkspaceId(member.userId);
    final stagedKinds = <String, String>{};
    final admissions = <_ControlAdmission>[];

    for (var index = 0; index < parsed.length; index++) {
      final header = parsed[index];
      if (header.opClass != opClassControl) {
        if (!workspaceExists) {
          throw SyncTransportException(409, 'ops[$index]', code: 'workspace_not_created');
        }
        _requireRole(grants, member.record.memberId, header.opClass, index);
        continue;
      }

      final Uint8List payloadBytes;
      try {
        payloadBytes = parseBody(splitEnvelope(envelopes[index]).body);
      } on SyncRejection catch (rejection) {
        throw SyncTransportException(422, 'ops[$index]', code: rejection.reason.code);
      }
      final ControlPayload payload;
      try {
        payload = ControlPayload.decode(payloadBytes);
        payload.requireServedType();
        payload.requireChainLinkShape();
      } on SyncRejection catch (rejection) {
        throw SyncTransportException(422, 'ops[$index]', code: rejection.reason.code);
      }

      if (payload.controlType == controlTypeWorkspaceGenesis) {
        admissions.add(await _verifyGenesis(
          payload,
          header,
          envelope: envelopes[index],
          index: index,
          workspaceId: workspaceId,
          member: member,
          rootPk: rootPk,
          workspaceExists: workspaceExists,
        ));
        workspaceExists = true;
        stagedKinds[admissions.last.registration!.memberId] =
            admissions.last.registration!.memberKind;
        continue;
      }

      if (!workspaceExists) {
        throw SyncTransportException(409, 'ops[$index]', code: 'workspace_not_created');
      }
      // A root-signed control payload lands regardless of Grants: that is how an
      // ungranted device's register-plus-grant batch gets in at all.
      if (!payload.isRootSigned) {
        _requireRole(grants, member.record.memberId, opClassControl, index);
      }

      switch (payload.controlType) {
        case controlTypeMemberRegister:
          final registration = await _verifyMemberRegister(
            payload,
            header,
            index: index,
            workspaceId: workspaceId,
            member: member,
            rootPk: rootPk,
          );
          stagedKinds[registration.memberId] = registration.memberKind;
          admissions.add(_ControlAdmission(
            index: index,
            controlType: payload.controlType,
            registration: registration,
          ));
        case controlTypeGrant:
          final grant = await _verifyGrant(
            payload,
            header,
            index: index,
            workspaceId: workspaceId,
            member: member,
            rootPk: rootPk,
            grants: grants,
            stagedKinds: stagedKinds,
            isPreferences: isPreferences,
            isReplay: replayedOpIds.contains(header.opId),
          );
          grants.add(grant.grantId, grant.memberId, grant.role);
          admissions.add(_ControlAdmission(
            index: index,
            controlType: payload.controlType,
            grant: grant,
          ));
        case controlTypeRevoke:
          final revoke = await _verifyRevoke(
            payload,
            header,
            index: index,
            workspaceId: workspaceId,
            member: member,
            rootPk: rootPk,
            grants: grants,
          );
          grants.revoke(revoke.grantId);
          admissions.add(_ControlAdmission(
            index: index,
            controlType: payload.controlType,
            revoke: revoke,
          ));
      }
    }
    return admissions;
  }

  /// The `(grant.role, header.op_class)` matrix, content-blind as ever.
  void _requireRole(_GrantIndex grants, String memberId, int opClass, int index) {
    final roles = grants.liveRoles(memberId);
    if (roles.isEmpty) {
      // `revoked` separates "never granted" from "granted and taken away".
      throw SyncTransportException(
        403,
        'ops[$index]${grants.hasAnyGrant(memberId) ? ' revoked' : ''}',
        code: 'no_live_grant',
      );
    }
    final allowed = roleOpClassMatrix[opClass] ?? const <String>{};
    if (roles.intersection(allowed).isEmpty) {
      throw SyncTransportException(403, 'ops[$index]', code: 'role_forbids_op_class');
    }
  }

  Future<_ControlAdmission> _verifyGenesis(
    ControlPayload payload,
    OpHeader header, {
    required Uint8List envelope,
    required int index,
    required String workspaceId,
    required _RegisteredMember member,
    required Uint8List rootPk,
    required bool workspaceExists,
  }) async {
    if (index != 0 || workspaceExists) {
      // First in the log and first in the batch. A second genesis is not a fork
      // for the server to resolve: it holds no control chain.
      throw SyncTransportException(409, 'ops[$index]', code: 'genesis_not_first');
    }
    if (!derivableWorkspaceIds(member.userId).contains(workspaceId)) {
      throw SyncTransportException(403, 'ops[$index]', code: 'workspace_not_derivable');
    }
    if (header.authorSeq != 1) {
      throw SyncTransportException(
        422,
        'ops[$index]: author_seq ${header.authorSeq}',
        code: 'member_register_not_first',
      );
    }
    if (!await verifyDomainSeparated(
      genesisSigningInput(payload.certBytes),
      payload.rootSig,
      rootPk,
    )) {
      throw SyncTransportException(422, 'ops[$index]', code: 'bad_root_signature');
    }
    final GenesisCertificate genesis;
    try {
      genesis = payload.genesisCertificate();
    } on SyncRejection catch (rejection) {
      throw SyncTransportException(422, 'ops[$index]', code: rejection.reason.code);
    }
    if (genesis.workspaceId != workspaceId) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_workspace_mismatch');
    }
    if (!_sameBytes(genesis.rootPk, rootPk)) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_root_pk_mismatch');
    }
    if (genesis.founder.memberId != header.authorMemberId) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_member_mismatch');
    }
    if (!_sameBytes(genesis.founder.signPk, member.record.signPk)) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_key_mismatch');
    }
    return _ControlAdmission(
      index: index,
      controlType: payload.controlType,
      registration: genesis.asRegistration(),
    );
  }

  Future<RegistrationCertificate> _verifyMemberRegister(
    ControlPayload payload,
    OpHeader header, {
    required int index,
    required String workspaceId,
    required _RegisteredMember member,
    required Uint8List rootPk,
  }) async {
    if (header.authorSeq != 1) {
      throw SyncTransportException(
        422,
        'ops[$index]: author_seq ${header.authorSeq}',
        code: 'member_register_not_first',
      );
    }
    if (!await verifyDomainSeparated(
      registrationSigningInput(payload.certBytes),
      payload.rootSig,
      rootPk,
    )) {
      throw SyncTransportException(422, 'ops[$index]', code: 'bad_root_signature');
    }
    final RegistrationCertificate certificate;
    try {
      certificate = payload.certificate();
    } on SyncRejection catch (rejection) {
      throw SyncTransportException(422, 'ops[$index]', code: rejection.reason.code);
    }
    if (certificate.workspaceId != workspaceId) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_workspace_mismatch');
    }
    if (certificate.memberId != header.authorMemberId) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_member_mismatch');
    }
    if (!_sameBytes(certificate.signPk, member.record.signPk)) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_key_mismatch');
    }
    return certificate;
  }

  Future<GrantCertificate> _verifyGrant(
    ControlPayload payload,
    OpHeader header, {
    required int index,
    required String workspaceId,
    required _RegisteredMember member,
    required Uint8List rootPk,
    required _GrantIndex grants,
    required Map<String, String> stagedKinds,
    required bool isPreferences,
    required bool isReplay,
  }) async {
    final GrantCertificate certificate;
    try {
      certificate = payload.grantCertificate();
    } on SyncRejection catch (rejection) {
      throw SyncTransportException(422, 'ops[$index]', code: rejection.reason.code);
    }
    if (certificate.workspaceId != workspaceId) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_workspace_mismatch');
    }
    if (certificate.granter != payload.authority) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_granter_mismatch');
    }
    final granterPk = _authorityPublicKey(payload.authority, header, index, rootPk, member);
    if (!await verifyDomainSeparated(
      grantSigningInput(payload.certBytes),
      payload.signature,
      granterPk,
    )) {
      throw SyncTransportException(422, 'ops[$index]', code: 'bad_grant_signature');
    }
    if (certificate.role == roleOwner && payload.authority != granterRoot) {
      throw SyncTransportException(422, 'ops[$index]', code: 'owner_grant_requires_root');
    }

    final grantee = _members[certificate.memberId];
    if (grantee == null || grantee.userId != member.userId) {
      throw SyncTransportException(422, 'ops[$index]', code: 'unknown_grantee');
    }
    final String memberKind;
    if (stagedKinds.containsKey(certificate.memberId)) {
      memberKind = stagedKinds[certificate.memberId]!;
    } else if (grantee.chained) {
      memberKind = grantee.memberKind ?? memberKindDevice;
    } else {
      // Fail closed on an unmaterialised grantee: never a dangling forward
      // reference, and the bar is the one the client's directory applies.
      throw SyncTransportException(422, 'ops[$index]', code: 'unknown_grantee');
    }
    if (isPreferences && memberKind != memberKindDevice) {
      throw SyncTransportException(422, 'ops[$index]', code: 'service_grant_forbidden');
    }
    if (!isReplay && grants.state(certificate.grantId) != null) {
      // A *different* op reusing a grant id. A replay of the op that minted the id
      // is excluded: it asserts nothing new, and dedupe is its business.
      throw SyncTransportException(409, 'ops[$index]', code: 'grant_id_already_used');
    }
    return certificate;
  }

  Future<RevokeCertificate> _verifyRevoke(
    ControlPayload payload,
    OpHeader header, {
    required int index,
    required String workspaceId,
    required _RegisteredMember member,
    required Uint8List rootPk,
    required _GrantIndex grants,
  }) async {
    final RevokeCertificate certificate;
    try {
      certificate = payload.revokeCertificate();
    } on SyncRejection catch (rejection) {
      throw SyncTransportException(422, 'ops[$index]', code: rejection.reason.code);
    }
    if (certificate.workspaceId != workspaceId) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_workspace_mismatch');
    }
    if (certificate.revoker != payload.authority) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_granter_mismatch');
    }
    final revokerPk = _authorityPublicKey(payload.authority, header, index, rootPk, member);
    if (!await verifyDomainSeparated(
      revokeSigningInput(payload.certBytes),
      payload.signature,
      revokerPk,
    )) {
      throw SyncTransportException(422, 'ops[$index]', code: 'bad_revoke_signature');
    }
    final target = grants.state(certificate.grantId);
    if (target == null) {
      throw SyncTransportException(422, 'ops[$index]', code: 'unknown_grantee');
    }
    if (target.role == roleOwner && payload.authority != granterRoot) {
      throw SyncTransportException(422, 'ops[$index]', code: 'owner_revoke_requires_root');
    }
    return certificate;
  }

  /// Root, or the authoring Member itself — authority does not travel by courier.
  Uint8List _authorityPublicKey(
    String authority,
    OpHeader header,
    int index,
    Uint8List rootPk,
    _RegisteredMember member,
  ) {
    if (authority == granterRoot) return rootPk;
    if (authority != header.authorMemberId) {
      throw SyncTransportException(422, 'ops[$index]', code: 'cert_granter_mismatch');
    }
    return member.record.signPk;
  }

  /// Write the index rows the batch's control ops stand for, once seqs exist.
  ///
  /// Returns the Members that lost their last live Grant, whose transport
  /// credentials and live sockets the caller then closes.
  List<String> _materialiseControl(
    String workspaceId,
    List<_ControlAdmission> admissions,
    List<OpAppendResult> results,
  ) {
    final index = _grants.putIfAbsent(workspaceId, () => {});
    final revokedFrom = <String>{};
    for (final admission in admissions) {
      final result = results[admission.index];
      if (result.duplicate) {
        // A verbatim replay: re-materialising would move `grantedSeq` off the op
        // that actually created the Grant.
        continue;
      }
      final registration = admission.registration;
      if (registration != null) {
        final row = _members[registration.memberId];
        if (row != null) {
          row.chained = true;
          row.memberKind = registration.memberKind;
        }
      }
      if (admission.controlType == controlTypeWorkspaceGenesis) {
        _workspaces[workspaceId] = result.seq;
      } else if (admission.grant != null) {
        index[admission.grant!.grantId] = _StoredGrant(
          grantId: admission.grant!.grantId,
          memberId: admission.grant!.memberId,
          role: admission.grant!.role,
          granter: admission.grant!.granter,
          grantedSeq: result.seq,
        );
      } else if (admission.revoke != null) {
        final target = index[admission.revoke!.grantId];
        if (target == null) continue;
        target.revokedBySeq = result.seq;
        revokedFrom.add(target.memberId);
      }
    }
    final stillLive = _GrantIndex(index);
    return [
      for (final memberId in revokedFrom)
        if (stillLive.liveRoles(memberId).isEmpty) memberId,
    ];
  }


  PullPage _pullOps(
    String memberId,
    String workspaceId, {
    required int since,
    required int limit,
  }) {
    final member = _members[memberId];
    if (member == null) {
      throw const SyncTransportException(401, 'unknown member', code: 'unknown_member');
    }
    _authorizeWorkspace(member.userId, workspaceId);
    // A **pre-genesis GET returns an empty page**, never an error: that is the
    // observation the enrolment ceremony branches on. `workspace_not_created` is
    // a POST-path refusal only, and this route simply has nothing to serve yet.
    _refuseIfRevoked(workspaceId, memberId);
    if (blindNextPullOf.remove(workspaceId)) {
      // Spent by being read: the next pull sees the log as it is, which is what
      // lets the losing device recover on its own.
      return const PullPage(ops: [], hasMore: false);
    }
    final floor = ignoreSinceParameter ? 0 : since;
    // Append order breaks every tie: [injectUnchecked] can spend one seq twice,
    // so seq alone is not a total order and a page would otherwise depend on the
    // sort's (unspecified) stability.
    final appendOrder = {for (var index = 0; index < _log.length; index++) _log[index]: index};
    int byAppendOrder(StoredOp a, StoredOp b) =>
        appendOrder[a]!.compareTo(appendOrder[b]!);
    final matching = [
      for (final op in _log)
        if (op.workspaceId == workspaceId &&
            op.seq > floor &&
            op.compactedBy == null &&
            !omitSeqs.contains(op.seq))
          op,
    ]..sort((a, b) {
      final bySeq = a.seq.compareTo(b.seq);
      return bySeq != 0 ? bySeq : byAppendOrder(a, b);
    });
    final order = serveOrder;
    if (order != null) {
      // Listed seqs first, in the listed order; everything else keeps its
      // ascending place behind them.
      matching.sort((a, b) {
        final left = order.indexOf(a.seq);
        final right = order.indexOf(b.seq);
        if (left == right) {
          final bySeq = a.seq.compareTo(b.seq);
          return bySeq != 0 ? bySeq : byAppendOrder(a, b);
        }
        if (left < 0) return 1;
        if (right < 0) return -1;
        return left.compareTo(right);
      });
    }
    final page = matching.take(limit).toList();
    return PullPage(
      ops: [for (final op in page) PulledOp(seq: op.seq, envelope: op.envelope)],
      hasMore: matching.length > limit,
    );
  }

  /// The outermost gate on every Workspace route: a User reaches the two
  /// Workspaces their id derives, and nothing else.
  void _authorizeWorkspace(String userId, String workspaceId) {
    if (!derivableWorkspaceIds(userId).contains(workspaceId)) {
      throw const SyncTransportException(
        403,
        'this User derives no such workspace',
        code: 'workspace_not_derivable',
      );
    }
  }

  /// The member-GET gate: an **unrevoked** member token is enough.
  ///
  /// Revocation is index-defined — at least one grant row and none live — so a
  /// *pre-grant* Member is admitted and a revoked one is refused immediately, on
  /// reads as well as writes. Admitting the pre-grant case is what lets the
  /// enrolment ceremony pull and apply the control log before it holds any Grant.
  void _refuseIfRevoked(String workspaceId, String memberId) {
    final index = _GrantIndex(_grants[workspaceId] ?? {});
    if (index.hasAnyGrant(memberId) && index.liveRoles(memberId).isEmpty) {
      throw const SyncTransportException(
        403,
        'no live Grant (revoked)',
        code: 'no_live_grant',
      );
    }
  }

  /// A live Grant's role, as the server's index holds it — the tamper hook.
  ///
  /// Flipping a role here and watching every client's verdict stay put is how
  /// "role elevation via server tables is impossible" is demonstrated rather than
  /// asserted: clients derive roles from the signed control ops in the log.
  void poisonGrantRole(String workspaceId, String grantId, String role) {
    final grant = _grants[workspaceId]?[grantId];
    if (grant == null) {
      throw StateError('no grant $grantId in $workspaceId to poison');
    }
    grant.role = role;
  }

  /// Un-revoke a Grant in the index without a control op behind it.
  ///
  /// The *served pre-revocation grant row*: a server can keep claiming a member
  /// is live after the log says otherwise. Chain-gating is what makes the claim
  /// inert on every client.
  void poisonGrantLiveness(String workspaceId, String grantId) {
    final grant = _grants[workspaceId]?[grantId];
    if (grant == null) {
      throw StateError('no grant $grantId in $workspaceId to poison');
    }
    grant.revokedBySeq = null;
  }

  /// Whether the index still shows a live Grant for [memberId].
  bool hasLiveGrant(String workspaceId, String memberId) =>
      _GrantIndex(_grants[workspaceId] ?? {}).liveRoles(memberId).isNotEmpty;

  static String _hex(Uint8List bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

/// A connection carrying the User's session credential.
///
/// No socket hangs off this one: `WS /w/{w}/signal` wants a member credential,
/// so the subscription lives on [FakeSyncServerMemberSession].
class FakeSyncServerUserSession implements UserTransport {
  FakeSyncServerUserSession(
    this.server,
    this.userId, {
    this.signalTimerFactory = Timer.new,
    this.keepaliveInterval = signalKeepaliveInterval,
  });

  final FakeSyncServer server;
  final String userId;

  /// Not used here — handed to the member session [completeMemberChallenge]
  /// mints, which is the one that can open a socket.
  final SignalTimerFactory signalTimerFactory;
  final Duration keepaliveInterval;

  String get workspaceId => defaultWorkspaceId(userId);

  @override
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
    required Uint8List kexPk,
  }) async =>
      server._registerMember(userId, memberId, signPk, kexPk);

  @override
  Future<RecoveryEscrowRecord?> fetchRecoveryEscrow(String workspaceId) async =>
      server._fetchRecoveryEscrow(userId, workspaceId);

  @override
  Future<RecoveryEscrowRecord> putRecoveryEscrow(
    String workspaceId,
    RecoveryEscrowRecord record,
  ) =>
      server._putRecoveryEscrow(userId, workspaceId, record);

  @override
  Future<Uint8List> requestMemberChallenge(String memberId) async =>
      server._requestMemberChallenge(memberId);

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) =>
      server._completeMemberChallenge(
        memberId,
        nonce,
        signature,
        signalTimerFactory: signalTimerFactory,
        keepaliveInterval: keepaliveInterval,
      );
}

/// A connection carrying one Member's transport credential.
///
/// Ops *and* the signal socket, because on the real server both live behind the
/// same member-scoped token.
class FakeSyncServerMemberSession implements SyncTransport {
  FakeSyncServerMemberSession(
    this.server,
    this.memberId, {
    this.signalTimerFactory = Timer.new,
    this.keepaliveInterval = signalKeepaliveInterval,
  });

  final FakeSyncServer server;
  final String memberId;
  final SignalTimerFactory signalTimerFactory;
  final Duration keepaliveInterval;

  /// The server side of the socket, before any client-side interpretation.
  /// [DeviceLink] listens here so it can inject faults at frame level.
  Stream<String> signalFrames(String workspaceId) => server._signalFrames(
        memberId,
        workspaceId,
        timerFactory: signalTimerFactory,
        keepaliveInterval: keepaliveInterval,
      );

  /// `GET /w/{w}/members` — deliberately **not** on [SyncTransport].
  ///
  /// This class doubles the server, so it models every endpoint the server
  /// serves; [SyncTransport] describes what a client calls, and nothing calls
  /// this one (see the note on [SyncTransport] for why the directory cannot be
  /// populated over HTTP). Keeping it here, on the member session, is what lets
  /// the contract twin pin the credential the route actually requires — the
  /// alternative was dropping the endpoint from the double, which is how the
  /// double came to be looser than the server in the first place.
  Future<List<MemberRecord>> fetchMembers(String workspaceId) async =>
      server._listMembers(memberId, workspaceId);

  @override
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  ) =>
      server._postOps(memberId, workspaceId, envelopes);

  @override
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
  }) async =>
      server._pullOps(memberId, workspaceId, since: since, limit: limit);

  @override
  Stream<void> newSeqSignals(String workspaceId) => decodeSignalFrames(
        () async => SignalSocket(
          frames: signalFrames(workspaceId),
          close: () async {},
        ),
        idleDeadline: keepaliveInterval * 3,
        timerFactory: signalTimerFactory,
      );
}
