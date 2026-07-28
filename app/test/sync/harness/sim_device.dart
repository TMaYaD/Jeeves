/// One simulated device: its own store, its own keypairs, a shared fake clock.
///
/// Everything a real device has except a UI and a network — which is the point.
/// The PowerSync engine could not run here, so the delete-on-absent windows in
/// `docs/SYNC.md` were only ever verified by hand; an op log over a plain
/// transport interface can be driven end to end in a unit test.
///
/// A device here enrols the same way a real one does: it runs the whole
/// ceremony in `EnrolmentService`, including obtaining Root from the passphrase.
/// No key is ever handed from one [SimDevice] to another, which is what makes
/// "a second device enrols with the passphrase alone" a claim the harness can
/// actually make.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/enrolment.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/passphrase_policy.dart';
import 'package:jeeves/sync/preferences_store.dart';
import 'package:jeeves/sync/recovery_escrow.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'fake_sync_server.dart';

/// Argon2id costs for the harness.
///
/// Reduced so a test suite that enrols dozens of devices does not spend minutes
/// in a pure-Dart KDF. They are injected as *both* the parameters and the floor,
/// so every blob still goes through the same floor-checking code path
/// production uses — the check is exercised, only the cost is not.
const Argon2idParameters harnessKdfParameters = Argon2idParameters(
  memoryKib: 32,
  timeCost: 1,
  parallelism: 1,
);

/// A manually advanced clock. Two devices reading the same value produce
/// genuinely concurrent HLCs, which is what the field-grain merge cases need —
/// racing real time would make them flaky instead of concurrent.
class FakeClock {
  FakeClock(this.nowMs);

  int nowMs;

  void advance(int milliseconds) => nowMs += milliseconds;

  DateTime get asDateTime => DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true);
}

/// The device's link to the server: where offline and fault injection live, so
/// [FakeSyncServer] stays a clean contract double.
///
/// It implements both credentials' surfaces because a *device* holds both — the
/// User's session and, after enrolment, its own. The server keeps them apart;
/// this is just where the network switch lives.
class DeviceLink implements SyncTransport, UserTransport {
  DeviceLink(this._userSession);

  final FakeSyncServerUserSession _userSession;
  SyncTransport? _memberSession;

  bool online = true;

  /// Simulates a POST whose ops the server accepted but whose response never
  /// arrived. The device must re-send on the next sync, and that re-send must
  /// be a no-op — which is exactly what op-id dedupe is for.
  bool dropPostResponse = false;

  void _requireOnline() {
    if (!online) {
      throw const SyncTransportException.unreachable('device is offline');
    }
  }

  SyncTransport get _member =>
      _memberSession ?? (throw StateError('device has not completed enrolment'));

  @override
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
    required Uint8List kexPk,
  }) async {
    _requireOnline();
    return _userSession.registerMember(
      memberId: memberId,
      signPk: signPk,
      kexPk: kexPk,
    );
  }

  @override
  Future<List<MemberRecord>> fetchMembers(String workspaceId) async {
    _requireOnline();
    return _userSession.fetchMembers(workspaceId);
  }

  @override
  Future<RecoveryEscrowRecord?> fetchRecoveryEscrow(String workspaceId) async {
    _requireOnline();
    return _userSession.fetchRecoveryEscrow(workspaceId);
  }

  @override
  Future<RecoveryEscrowRecord> putRecoveryEscrow(
    String workspaceId,
    RecoveryEscrowRecord record,
  ) async {
    _requireOnline();
    return _userSession.putRecoveryEscrow(workspaceId, record);
  }

  @override
  Future<Uint8List> requestMemberChallenge(String memberId) async {
    _requireOnline();
    return _userSession.requestMemberChallenge(memberId);
  }

  @override
  Future<SyncTransport> completeMemberChallenge({
    required String memberId,
    required Uint8List nonce,
    required Uint8List signature,
  }) async {
    _requireOnline();
    _memberSession = await _userSession.completeMemberChallenge(
      memberId: memberId,
      nonce: nonce,
      signature: signature,
    );
    // The client syncs through the link, not around it, so `goOffline` keeps
    // working after enrolment.
    return this;
  }

  @override
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  ) async {
    _requireOnline();
    final results = await _member.postOps(workspaceId, envelopes);
    if (dropPostResponse) {
      throw const SyncTransportException.unreachable('response lost after append');
    }
    return results;
  }

  @override
  Future<PullPage> pullOps(
    String workspaceId, {
    required int since,
    required int limit,
  }) async {
    _requireOnline();
    return _member.pullOps(workspaceId, since: since, limit: limit);
  }
}

class SimDevice {
  SimDevice._({
    required this.label,
    required this.userId,
    required this.database,
    required this.identity,
    required this.clock,
    required this.hlc,
    required this.registry,
    required this.client,
    required this.link,
    required this.keyStore,
    required this.enrolment,
    required this.outcome,
  }) : preferences = PreferencesStore(client: client, registry: registry);

  /// Build a device and run the enrolment ceremony on it.
  ///
  /// [passphrase] is null for the very first device of an account — the
  /// ceremony generates one and hands it back on [outcome], which is the only
  /// thing any later device is given.
  static Future<SimDevice> create({
    required String label,
    required String userId,
    required FakeSyncServer server,
    required FakeClock clock,
    String? memberId,
    Uint8List? seed,
    String? passphrase,
    Random? random,
    Argon2idParameters kdf = harnessKdfParameters,
    PassphrasePolicy passphrasePolicy = const PassphrasePolicy(),
  }) async {
    // N devices means N stores, which is the whole premise. Drift's warning is
    // about several databases sharing one executor; each device here has its
    // own in-memory one, so there is nothing to race.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final database = SyncDatabase(NativeDatabase.memory());
    final identity = await MemberIdentity.generate(
      memberId: memberId,
      signSeed: seed,
      // A distinct KEX seed from the same deterministic source: using one seed
      // for two algorithms is exactly what F8's separate keys forbid.
      kexSeed: seed == null
          ? null
          : Uint8List.fromList([for (final byte in seed) (byte + 0x5A) % 256]),
    );
    final hlc = HlcClock(
      memberIdHex: identity.memberIdHex,
      nowMs: () => clock.nowMs,
    );
    final registry = CollectionRegistry(database);
    final link = DeviceLink(server.connectAsUser(userId));
    final client = SyncClient(
      workspaceId: implicitWorkspaceId(userId),
      userId: userId,
      identity: identity,
      database: database,
      clock: hlc,
      reducer: Reducer(database, nowMs: () => clock.nowMs),
      now: () => clock.asDateTime,
    );
    final keyStore = InMemoryDeviceKeyStore();
    final enrolment = EnrolmentService(
      client: client,
      userTransport: link,
      keyStore: keyStore,
      nowMs: () => clock.nowMs,
      passphrasePolicy: passphrasePolicy,
      kdfParameters: kdf,
      kdfFloor: kdf,
      random: random ?? Random(label.codeUnitAt(0)),
    );
    final outcome = passphrase == null
        ? await enrolment.enrolFirstDevice()
        : await enrolment.enrolWithPassphrase(passphrase);

    return SimDevice._(
      label: label,
      userId: userId,
      database: database,
      identity: identity,
      clock: clock,
      hlc: hlc,
      registry: registry,
      client: client,
      link: link,
      keyStore: keyStore,
      enrolment: enrolment,
      outcome: outcome,
    );
  }

  final String label;
  final String userId;
  final SyncDatabase database;
  final MemberIdentity identity;
  final FakeClock clock;
  final HlcClock hlc;
  final CollectionRegistry registry;
  final SyncClient client;
  final DeviceLink link;
  final DeviceKeyStore keyStore;
  final EnrolmentService enrolment;

  /// What this device's enrolment produced — including the passphrase, which
  /// for the first device is the only copy that will ever exist.
  final EnrolmentOutcome outcome;

  final PreferencesStore preferences;

  void goOffline() => link.online = false;

  void goOnline() => link.online = true;

  /// Push, then pull. There is no directory refresh: a MemberRegister is its
  /// author's op 1, so the pull hydrates the directory in order by itself.
  Future<void> sync() => client.sync();

  /// Sync, tolerating the offline case — for tests that just want everyone as
  /// converged as the network allows.
  Future<void> syncIfOnline() async {
    if (!link.online) return;
    await sync();
  }

  Future<void> close() => database.close();
}
