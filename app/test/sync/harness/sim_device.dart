/// One simulated device: its own store, its own keypair, a shared fake clock.
///
/// Everything a real device has except a UI and a network — which is the point.
/// The PowerSync engine could not run here, so the delete-on-absent windows in
/// `docs/SYNC.md` were only ever verified by hand; an op log over a plain
/// transport interface can be driven end to end in a unit test.
library;

import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/domain_projector.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/merge_strategy.dart';
import 'package:jeeves/sync/preferences_store.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_health.dart';
import 'package:jeeves/sync/sync_transport.dart';

import 'fake_sync_server.dart';

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
class DeviceLink implements SyncTransport {
  DeviceLink(this._session);

  final FakeSyncServerSession _session;

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

  @override
  Future<MemberRecord> registerMember({
    required String memberId,
    required Uint8List signPk,
  }) async {
    _requireOnline();
    return _session.registerMember(memberId: memberId, signPk: signPk);
  }

  @override
  Future<List<MemberRecord>> fetchMembers(String workspaceId) async {
    _requireOnline();
    return _session.fetchMembers(workspaceId);
  }

  @override
  Future<List<OpAppendResult>> postOps(
    String workspaceId,
    List<Uint8List> envelopes,
  ) async {
    _requireOnline();
    final results = await _session.postOps(workspaceId, envelopes);
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
    return _session.pullOps(workspaceId, since: since, limit: limit);
  }
}

class SimDevice {
  SimDevice._({
    required this.label,
    required this.userId,
    required this.database,
    required this.domain,
    required this.identity,
    required this.clock,
    required this.hlc,
    required this.registry,
    required this.client,
    required this.link,
    required this.projector,
  }) : preferences = PreferencesStore(client: client, registry: registry);

  static Future<SimDevice> create({
    required String label,
    required String userId,
    required FakeSyncServer server,
    required FakeClock clock,
    String? memberId,
    Uint8List? seed,
    MergeStrategyRegistry strategies = const MergeStrategyRegistry(),
  }) async {
    // N devices means N stores, which is the whole premise. Drift's warning is
    // about several databases sharing one executor; each device here has its
    // own in-memory one, so there is nothing to race.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final database = SyncDatabase(NativeDatabase.memory());
    final identity = await MemberIdentity.generate(memberId: memberId, seed: seed);
    final hlc = HlcClock(
      memberIdHex: identity.memberIdHex,
      nowMs: () => clock.nowMs,
    );
    final registry = CollectionRegistry(database);
    final link = DeviceLink(server.connectAs(userId));
    final client = SyncClient(
      workspaceId: implicitWorkspaceId(userId),
      identity: identity,
      transport: link,
      database: database,
      clock: hlc,
      reducer: Reducer(
        database,
        nowMs: () => clock.nowMs,
        strategies: strategies,
      ),
      now: () => clock.asDateTime,
    );
    // The two stores and the wiring #553 flips on, in the order the cycle
    // allows: the capture seam needs the client, the domain store needs the
    // seam, and the projector needs the domain store.
    final domain = GtdDatabase(
      NativeDatabase.memory(),
      opCapture: SyncOpCapture(client),
    );
    final projector = DomainProjector(registry: registry, domain: domain);
    client.projector = projector;
    final device = SimDevice._(
      label: label,
      userId: userId,
      database: database,
      domain: domain,
      identity: identity,
      clock: clock,
      hlc: hlc,
      registry: registry,
      client: client,
      link: link,
      projector: projector,
    );
    await client.enrol();
    return device;
  }

  final String label;
  final String userId;

  /// The convergence substrate: reduced fields, clocks, tombstones, the log.
  final SyncDatabase database;

  /// The domain read model the projector feeds, and the DAOs write through.
  final GtdDatabase domain;

  final MemberIdentity identity;
  final FakeClock clock;
  final HlcClock hlc;
  final CollectionRegistry registry;
  final SyncClient client;
  final DeviceLink link;
  final DomainProjector projector;
  final PreferencesStore preferences;

  void goOffline() => link.online = false;

  void goOnline() => link.online = true;

  /// A real client learns about new members before it can verify their ops, so
  /// the directory refresh is part of a sync, not a one-off at enrolment.
  Future<SyncHealth> sync() async {
    await client.refreshMemberDirectory();
    return client.sync();
  }

  /// Sync, tolerating the offline case — for tests that just want everyone as
  /// converged as the network allows.
  Future<void> syncIfOnline() async {
    if (!link.online) return;
    await sync();
  }

  Future<void> close() async {
    await domain.close();
    await database.close();
  }
}
