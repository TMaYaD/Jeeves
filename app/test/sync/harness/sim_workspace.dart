/// N simulated devices of one User against one fake server.
///
/// Device A enrols first and its ceremony *generates* the passphrase; every
/// later device is handed that string and nothing else. No keypair, no Root, no
/// shared store — which is what makes "a second device enrols with the
/// passphrase alone" something the harness demonstrates rather than assumes.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:jeeves/sync/control_payload.dart';
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/merge_strategy.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/root_authority.dart';
import 'package:jeeves/sync/signal_socket.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:uuid/uuid.dart';

import 'author_fixture.dart';
import 'fake_sync_server.dart';
import 'sim_device.dart';

/// Mint a MemberRegister envelope for [device], signed by [root].
///
/// The one place the harness builds a control op, so a test that wants a *bad*
/// one changes an argument rather than reimplementing the format.
Future<Uint8List> memberRegisterEnvelope({
  required AuthorFixture device,
  required String workspaceId,
  required RootAuthority root,
  required Uint8List prevControlHash,
  required int wallMs,
  RegistrationCertificate? certificate,
  bool corruptSignature = false,
  int? authorSeq,
}) async {
  final cert = certificate ??
      RegistrationCertificate(
        workspaceId: workspaceId,
        memberId: device.memberId,
        signPk: device.signPk,
        kexPk: device.kexPk,
        registeredAtHlc: Hlc.forMember(device.memberId, wallMs),
      );
  final certBytes = cert.encode();
  final signature = await root.signCertificateBytes(certBytes);
  if (corruptSignature) signature[signature.length - 1] ^= 0x01;
  return device.nextEnvelope(
    workspaceId,
    opClass: opClassControl,
    payload: ControlPayload(
      controlType: controlTypeMemberRegister,
      prevControlHash: prevControlHash,
      certBytes: certBytes,
      signature: signature,
    ).encode(),
    authorSeq: authorSeq,
  );
}

/// Mint a `workspace_genesis` envelope for [device], signed by [root].
///
/// Genesis embeds the founding Device's registration, so this is also how the
/// harness brings a founder's *keys* into a Workspace (ADR-0031).
Future<Uint8List> workspaceGenesisEnvelope({
  required AuthorFixture device,
  required String workspaceId,
  required RootAuthority root,
  required int wallMs,
  Uint8List? rootPk,
  Uint8List? prevControlHash,
  bool corruptSignature = false,
  int? authorSeq,
}) async {
  final certificate = GenesisCertificate(
    workspaceId: workspaceId,
    rootPk: rootPk ?? root.rootPk,
    founder: MemberKeys(
      memberId: device.memberId,
      signPk: device.signPk,
      kexPk: device.kexPk,
    ),
    createdAtHlc: Hlc.forMember(device.memberId, wallMs),
  );
  final certBytes = certificate.encode();
  final signature = await root.signGenesisCertificateBytes(certBytes);
  if (corruptSignature) signature[signature.length - 1] ^= 0x01;
  return device.nextEnvelope(
    workspaceId,
    opClass: opClassControl,
    payload: ControlPayload(
      controlType: controlTypeWorkspaceGenesis,
      prevControlHash: prevControlHash ?? zeroPrevControlHash,
      certBytes: certBytes,
      signature: signature,
    ).encode(),
    authorSeq: authorSeq,
  );
}

/// Mint a `grant` envelope. [signingKey] null means Root signs it.
///
/// Root for an `owner` role — the only authority that may mint one (ADR-0031) —
/// and an owning Device's own key for anything less.
Future<Uint8List> grantEnvelope({
  required AuthorFixture device,
  required String workspaceId,
  required RootAuthority root,
  required Uint8List prevControlHash,
  required String memberId,
  required int wallMs,
  String role = roleOwner,
  String? granter,
  String? grantId,
  AuthorFixture? signer,
  bool corruptSignature = false,
  int? authorSeq,
}) async {
  final resolvedGranter = granter ?? granterRoot;
  final certificate = GrantCertificate(
    workspaceId: workspaceId,
    grantId: grantId ?? const Uuid().v4(),
    memberId: memberId,
    role: role,
    granter: resolvedGranter,
    grantedAtHlc: Hlc.forMember(memberId, wallMs),
  );
  final certBytes = certificate.encode();
  final signature = signer == null
      ? await root.signGrantCertificateBytes(certBytes)
      : await signer.signGrantCertificateBytes(certBytes);
  if (corruptSignature) signature[signature.length - 1] ^= 0x01;
  return device.nextEnvelope(
    workspaceId,
    opClass: opClassControl,
    payload: ControlPayload(
      controlType: controlTypeGrant,
      prevControlHash: prevControlHash,
      certBytes: certBytes,
      signature: signature,
      authority: resolvedGranter,
    ).encode(),
    authorSeq: authorSeq,
  );
}

/// Mint a `revoke` envelope naming one [grantId]. Revocation is grant-granular.
Future<Uint8List> revokeEnvelope({
  required AuthorFixture device,
  required String workspaceId,
  required RootAuthority root,
  required Uint8List prevControlHash,
  required String grantId,
  required int wallMs,
  String? revoker,
  AuthorFixture? signer,
  bool corruptSignature = false,
  int? authorSeq,
}) async {
  final resolvedRevoker = revoker ?? granterRoot;
  final revokeId = const Uuid().v4();
  final certificate = RevokeCertificate(
    workspaceId: workspaceId,
    revokeId: revokeId,
    grantId: grantId,
    revoker: resolvedRevoker,
    // The HLC's tie-breaker node is a *member* id — that is what `Hlc.forMember`
    // stores and what the fork tie-break compares. Passing the freshly minted
    // `revoke_id` would order revocations by a certificate id instead of by the
    // device that authored them. Mirrors `backend/tests/sync/builders.py`.
    revokedAtHlc: Hlc.forMember(device.memberId, wallMs),
  );
  final certBytes = certificate.encode();
  final signature = signer == null
      ? await root.signRevokeCertificateBytes(certBytes)
      : await signer.signRevokeCertificateBytes(certBytes);
  if (corruptSignature) signature[signature.length - 1] ^= 0x01;
  return device.nextEnvelope(
    workspaceId,
    opClass: opClassControl,
    payload: ControlPayload(
      controlType: controlTypeRevoke,
      prevControlHash: prevControlHash,
      certBytes: certBytes,
      signature: signature,
      authority: resolvedRevoker,
    ).encode(),
    authorSeq: authorSeq,
  );
}

/// Mint a `rotate` envelope. **The one control type with no certificate**, so there
/// is no signing key argument: a rotate's authority is the author's own live `owner`
/// Grant, and the envelope signature is the only signature it carries.
Future<Uint8List> rotateEnvelope({
  required AuthorFixture device,
  required String workspaceId,
  required Uint8List prevControlHash,
  required Uint8List keyWrapDigest,
  required int wallMs,
  int fromEpoch = 0,
  int? toEpoch,
  int? authorSeq,
}) =>
    device.nextEnvelope(
      workspaceId,
      opClass: opClassControl,
      payload: ControlPayload(
        controlType: controlTypeRotate,
        prevControlHash: prevControlHash,
        rotate: RotateStatement(
          workspaceId: workspaceId,
          fromEpoch: fromEpoch,
          toEpoch: toEpoch ?? fromEpoch + 1,
          keyWrapDigest: keyWrapDigest,
          rotatedAtHlc: Hlc.forMember(device.memberId, wallMs),
        ),
      ).encode(),
      authorSeq: authorSeq,
    );

/// The base wall time the fake clock starts at. Fixed so HLCs in failure
/// messages are readable and reproducible.
const int simulationStartWallMs = 1800000000000;

class SimWorkspace {
  SimWorkspace._(this.server, this.clock, this.timers, this.userId, this.devices);

  static Future<SimWorkspace> create({
    int deviceCount = 2,
    String userId = 'sim-user',
    FakeSyncServer? server,
    FakeClock? clock,
    MergeStrategyRegistry strategies = const MergeStrategyRegistry(),
    SimTimers? timers,
    Duration keepaliveInterval = signalKeepaliveInterval,
    int pullPageLimit = defaultPullPageLimit,
  }) async {
    final sharedServer = server ?? FakeSyncServer();
    final sharedClock = clock ?? FakeClock(simulationStartWallMs);
    // One wheel for the whole workspace, so `timers.advance` moves every
    // device's keepalives and deadlines together — the same wall clock they
    // would share in the field.
    final sharedTimers = timers ?? SimTimers();
    final devices = <SimDevice>[];
    for (var index = 0; index < deviceCount; index++) {
      devices.add(
        await SimDevice.create(
          label: String.fromCharCode('A'.codeUnitAt(0) + index),
          userId: userId,
          server: sharedServer,
          clock: sharedClock,
          strategies: strategies,
          timers: sharedTimers,
          keepaliveInterval: keepaliveInterval,
          pullPageLimit: pullPageLimit,
          // Deterministic identity: HLC ties break on the member id, so a
          // random one would make the tie-break cases reproduce differently
          // from run to run.
          memberId: const Uuid().v5(jeevesWorkspaceNamespace, 'sim/device/$index'),
          seed: Uint8List.fromList(
            List<int>.generate(32, (byte) => (byte + index * 31 + 1) % 256),
          ),
          // The first device mints the passphrase; the rest are told it, which
          // is all a real user carries from one device to the next.
          passphrase: index == 0 ? null : devices.first.outcome.passphrase,
          random: Random(1000 + index),
        ),
      );
    }
    return SimWorkspace._(sharedServer, sharedClock, sharedTimers, userId, devices);
  }

  final FakeSyncServer server;
  final FakeClock clock;
  final SimTimers timers;
  final String userId;
  final List<SimDevice> devices;

  String get workspaceId => defaultWorkspaceId(userId);

  /// The implicit User-global preferences Workspace — every Device, no Service.
  String get preferencesWorkspaceId => userPreferencesWorkspaceId(userId);

  /// The passphrase device A generated. The only secret that travels between
  /// devices in this harness.
  String get passphrase => devices.first.outcome.passphrase;

  SimDevice get a => devices[0];

  SimDevice get b => devices[1];

  /// Recover Root the way a device would: fetch the escrow, unwrap it with the
  /// passphrase.
  ///
  /// Tests that need to mint a certificate — a genuine one, or a deliberately
  /// bad one — go through this rather than being handed a key, so nothing in
  /// the harness gets Root by a route a real client could not take.
  Future<RootAuthority> recoverRoot() async {
    final record = await server.connectAsUser(userId).fetchRecoveryEscrow(workspaceId);
    final secrets = await unwrapEscrowBlob(
      blob: record!.blob,
      passphrase: passphrase,
      floor: harnessKdfParameters,
    );
    return RootAuthority.fromSecretKey(secrets.rootSecretKey);
  }

  /// The chain link the next control op must name.
  ///
  /// Computed from the log the way any client that pulled it would: the hash of
  /// the payload bytes of the last control op there, or all-zero when the log
  /// holds none. Not a server capability — the real server never walks the
  /// control chain — but the harness needs to author ops a pulling client will
  /// accept, and this is how a pulling client sees it.
  Uint8List controlChainHead({String? workspace}) {
    final target = workspace ?? workspaceId;
    for (final op in server.storedOps.reversed) {
      final header = op.header;
      if (op.workspaceId != target || header?.opClass != opClassControl) continue;
      return controlPayloadHash(parseBody(splitEnvelope(op.envelope).body));
    }
    return zeroPrevControlHash;
  }

  /// The grant id of [memberId]'s Grant, read off the log.
  ///
  /// Read from the *signed control ops* rather than from any server table, which
  /// is the only way a test can name a Grant without borrowing the server's word
  /// for it — so the scan lives here once and not per test file.
  ///
  /// [role] null matches the first Grant for the member whatever its role.
  String grantIdOf(String memberId, {String? role, String? workspace}) {
    final target = workspace ?? workspaceId;
    for (final op in server.storedOps) {
      final header = op.header;
      if (op.workspaceId != target || header?.opClass != opClassControl) continue;
      final payload = ControlPayload.decode(parseBody(splitEnvelope(op.envelope).body));
      if (payload.controlType != controlTypeGrant) continue;
      final grant = payload.grantCertificate();
      if (grant.memberId != memberId) continue;
      if (role != null && grant.role != role) continue;
      return grant.grantId;
    }
    throw StateError(
      'no ${role ?? 'any-role'} Grant for $memberId in $target',
    );
  }

  /// The device's own owner Grant — what a revocation test takes away.
  String ownerGrantIdOf(String memberId, {String? workspace}) =>
      grantIdOf(memberId, role: roleOwner, workspace: workspace);

  /// Bring an [AuthorFixture] in as a genuinely chained, genuinely granted Member.
  ///
  /// Registers its keys, takes a member credential by proof of possession, and
  /// posts a real Root-signed MemberRegister plus an explicit Grant at the head of
  /// the control chain — the same two-op shape `EnrolmentService` posts, because
  /// roles are one materialisation path and there are no implied grants.
  ///
  /// A test that wants an author every device will *accept* uses this; a test that
  /// wants one every device must *refuse* skips it, or passes [grant] false to get
  /// a chained-but-ungranted author.
  Future<FakeSyncServerMemberSession> enrolFixture(
    AuthorFixture device, {
    bool grant = true,
    String role = roleOwner,
    String? workspace,
  }) async {
    final target = workspace ?? workspaceId;
    final user = server.connectAsUser(userId);
    await user.registerMember(
      memberId: device.memberId,
      signPk: device.signPk,
      kexPk: device.kexPk,
    );
    final nonce = await user.requestMemberChallenge(device.memberId);
    final session = await user.completeMemberChallenge(
      memberId: device.memberId,
      nonce: nonce,
      signature: await device.signChallenge(nonce),
    ) as FakeSyncServerMemberSession;

    final root = await recoverRoot();
    try {
      final register = await memberRegisterEnvelope(
        device: device,
        workspaceId: target,
        root: root,
        prevControlHash: controlChainHead(workspace: target),
        wallMs: clock.nowMs,
      );
      // **One** POST, register at index 0 and the Grant at index 1 — the batch shape
      // `EnrolmentService` actually posts. Two POSTs would leave the real path
      // untested: a Grant authorizing against a register that landed in the *same*
      // atomic append is precisely what the batch walk has to get right.
      final founding = [
        register,
        if (grant)
          await grantEnvelope(
            device: device,
            workspaceId: target,
            root: root,
            prevControlHash: controlPayloadHash(parseBody(splitEnvelope(register).body)),
            memberId: device.memberId,
            role: role,
            wallMs: clock.nowMs,
          ),
      ];
      await session.postOps(target, founding);
      return session;
    } finally {
      // Every other Root-holding path in the harness drops in a `finally`, and a
      // refused post is exactly what the negative tests stage: without this a
      // failing ceremony would leave Root live for the rest of the test.
      root.drop();
    }
  }

  /// Bring [service] in as a chained, granted **Service** rather than a Device.
  ///
  /// The `member_kind` is a *signed* fact, so this differs from [enrolFixture] in
  /// exactly one field — the registration certificate's kind — and everything else is
  /// the same two-op ceremony. It exists because a live-granted Service is the one
  /// reachable state in which a Workspace has a Member no epoch key can be wrapped
  /// to: Service KeyWraps need a verified per-User KEX subkey, and Service enrolment
  /// does not exist yet.
  ///
  /// The default Workspace only. The preferences Workspace refuses a Service Grant on
  /// both sides, which is a different rule and has its own test.
  Future<FakeSyncServerMemberSession> enrolServiceFixture(
    AuthorFixture service, {
    String role = roleSuggester,
  }) async {
    final user = server.connectAsUser(userId);
    await user.registerMember(
      memberId: service.memberId,
      signPk: service.signPk,
      kexPk: service.kexPk,
    );
    final nonce = await user.requestMemberChallenge(service.memberId);
    final session = await user.completeMemberChallenge(
      memberId: service.memberId,
      nonce: nonce,
      signature: await service.signChallenge(nonce),
    ) as FakeSyncServerMemberSession;

    final root = await recoverRoot();
    try {
      final register = await memberRegisterEnvelope(
        device: service,
        workspaceId: workspaceId,
        root: root,
        prevControlHash: controlChainHead(),
        wallMs: clock.nowMs,
        certificate: RegistrationCertificate(
          workspaceId: workspaceId,
          memberId: service.memberId,
          signPk: service.signPk,
          kexPk: service.kexPk,
          registeredAtHlc: Hlc.forMember(service.memberId, clock.nowMs),
          memberKind: memberKindService,
        ),
      );
      await session.postOps(workspaceId, [
        register,
        await grantEnvelope(
          device: service,
          workspaceId: workspaceId,
          root: root,
          prevControlHash: controlPayloadHash(parseBody(splitEnvelope(register).body)),
          memberId: service.memberId,
          role: role,
          wallMs: clock.nowMs,
        ),
      ]);
      return session;
    } finally {
      root.drop();
    }
  }

  /// Push everyone, then pull everyone, twice — one pass would leave the first
  /// device having pulled before the last device pushed.
  Future<void> syncAll() async {
    for (var round = 0; round < 2; round++) {
      for (final device in devices) {
        await device.syncIfOnline();
      }
    }
  }

  Future<void> close() async {
    for (final device in devices) {
      await device.close();
    }
  }
}
