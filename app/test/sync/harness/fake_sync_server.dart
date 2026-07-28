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

  /// Stamped when a Root-signed MemberRegister for this member materialises.
  bool chained = false;
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
  int _nextSeq = 1;

  /// Dart mirror of `backend/app/sync/signal_hub.py`: subscribers per Workspace
  /// and nothing else — no seqs, no cursors, no history.
  final Map<String, List<void Function(String)>> _signalSubscribers = {};

  /// Every batch the server accepted for a POST, in order — lets a test assert
  /// what actually went over the wire.
  final List<List<Uint8List>> receivedBatches = [];

  /// Every escrow read, in order: the append-only audit the real server keeps.
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

  /// Append bytes without running any of the server's own checks.
  ///
  /// This is the *hostile or broken server*: the fail-closed rules on the
  /// client exist precisely because nothing stops a server from serving an
  /// envelope it should have refused, or one it forged. Returns the assigned
  /// seq.
  int injectUnchecked(String workspaceId, Uint8List envelope) {
    OpHeader? header;
    try {
      header = OpHeader.parse(envelope);
    } on SyncRejection {
      header = null;
    }
    final op = StoredOp(
      seq: _nextSeq++,
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
    for (final send in [...?_signalSubscribers[workspaceId]]) {
      send('');
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
      } on SyncTransportException {
        controller.addError(
          const SyncTransportException(
            signalCloseForbidden,
            'No grant for this workspace',
            // The structured code the real 403 carries. A close frame cannot
            // hold a body, so the client branches on the close code — but the
            // fake keeps the code alongside it rather than regressing to a bare
            // string, so a twin can assert the same contract on both sides.
            code: 'no_workspace_grant',
          ),
        );
        unawaited(controller.close());
        return;
      }
      _signalSubscribers.putIfAbsent(workspaceId, () => []).add(send);
      // The initial poke is the subscribe ack *and* the catch-up trigger.
      send('');
    };
    controller.onCancel = () {
      keepalive?.cancel();
      _signalSubscribers[workspaceId]?.remove(send);
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
    final count = (_escrowFetchCounts[userId] ?? 0) + 1;
    _escrowFetchCounts[userId] = count;
    if (count > fakeServerRecoveryFetchLimit) {
      throw const SyncTransportException(
        429,
        'retry_after_seconds $fakeServerRecoveryFetchWindowSeconds',
        code: 'escrow_fetch_rate_limited',
      );
    }
    final stored = _escrows[_slot(workspaceId, userId)];
    if (stored == null) return null;
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
    final chains = await _verifyControlOps(member, workspaceId, envelopes, parsed);

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
        throw SyncTransportException(
          409,
          'ops[$index]: author_seq ${header.authorSeq}, expected $expected',
          code: 'author_chain_gap',
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
    for (final chained in chains) {
      chained.chained = true;
    }
    receivedBatches.add(List.unmodifiable(envelopes));
    if (staged.isNotEmpty) {
      // Only non-duplicate appends are news: a pure replay changes nothing, so
      // poking about it would send every subscriber on a pointless pull.
      _notify(workspaceId);
    }
    return [
      for (final entry in plan)
        OpAppendResult(
          opId: entry.opId,
          seq: entry.seq ?? entry.op!.seq,
          duplicate: entry.duplicate,
        ),
    ];
  }

  /// The six server-side control checks, in the same order as the real route.
  Future<List<_RegisteredMember>> _verifyControlOps(
    _RegisteredMember member,
    String workspaceId,
    List<Uint8List> envelopes,
    List<OpHeader> parsed,
  ) async {
    final toChain = <_RegisteredMember>[];
    for (var index = 0; index < parsed.length; index++) {
      final header = parsed[index];
      if (header.opClass != opClassControl) continue;

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
      } on SyncRejection catch (rejection) {
        throw SyncTransportException(422, 'ops[$index]', code: rejection.reason.code);
      }

      if (header.authorSeq != 1) {
        throw SyncTransportException(
          422,
          'ops[$index]: author_seq ${header.authorSeq}',
          code: 'member_register_not_first',
        );
      }

      final escrow = _escrows[_slot(workspaceId, member.userId)];
      // No escrow means no Root the server can check against.
      final rootPk = escrow?.record.rootPk ?? Uint8List(0);
      final signed = await verifyDomainSeparated(
        registrationSigningInput(payload.certBytes),
        payload.rootSig,
        rootPk,
      );
      if (!signed) {
        throw SyncTransportException(422, 'ops[$index]', code: 'bad_root_signature');
      }
      final RegistrationCertificate certificate;
      try {
        certificate = payload.certificate();
      } on SyncRejection catch (rejection) {
        throw SyncTransportException(422, 'ops[$index]', code: rejection.reason.code);
      }
      if (certificate.memberId != header.authorMemberId) {
        throw SyncTransportException(422, 'ops[$index]', code: 'cert_member_mismatch');
      }
      if (!_sameBytes(certificate.signPk, member.record.signPk)) {
        throw SyncTransportException(422, 'ops[$index]', code: 'cert_key_mismatch');
      }
      toChain.add(member);
    }
    return toChain;
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
    final matching = [
      for (final op in _log)
        if (op.workspaceId == workspaceId && op.seq > since && op.compactedBy == null)
          op,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
    final page = matching.take(limit).toList();
    return PullPage(
      ops: [for (final op in page) PulledOp(seq: op.seq, envelope: op.envelope)],
      hasMore: matching.length > limit,
    );
  }

  void _authorizeWorkspace(String userId, String workspaceId) {
    if (workspaceId != implicitWorkspaceId(userId)) {
      throw const SyncTransportException(
        403,
        'No grant for this workspace',
        code: 'no_workspace_grant',
      );
    }
  }

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

  String get workspaceId => implicitWorkspaceId(userId);

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
