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
      rootSig: signature,
    ).encode(),
    authorSeq: authorSeq,
  );
}

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

  String get workspaceId => implicitWorkspaceId(userId);

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
  Uint8List controlChainHead() {
    for (final op in server.storedOps.reversed) {
      final header = op.header;
      if (op.workspaceId != workspaceId || header?.opClass != opClassControl) continue;
      return controlPayloadHash(parseBody(splitEnvelope(op.envelope).body));
    }
    return zeroPrevControlHash;
  }

  /// Bring an [AuthorFixture] in as a genuinely chained Member.
  ///
  /// Registers its keys, takes a member credential by proof of possession, and
  /// posts a real Root-signed MemberRegister at the head of the control chain.
  /// A test that wants an author every device will *accept* uses this; a test
  /// that wants one every device must *refuse* simply skips it.
  Future<FakeSyncServerMemberSession> enrolFixture(AuthorFixture device) async {
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
    await session.postOps(workspaceId, [
      await memberRegisterEnvelope(
        device: device,
        workspaceId: workspaceId,
        root: root,
        prevControlHash: controlChainHead(),
        wallMs: clock.nowMs,
      ),
    ]);
    root.drop();
    return session;
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
