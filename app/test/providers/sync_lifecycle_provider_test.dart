/// The signed-out branch of `syncLifecycleProvider`: who settles the capture
/// seam when no lifecycle ever will.
///
/// A local-only user never builds a `SyncLifecycle`, so nobody down that path
/// ever *decides* the seam — and the seam buffers from construction. The provider
/// is what settles it silent, but only once session restore has answered: while
/// restore is still in flight the user reads `'local'`, and that is exactly the
/// enrolled-relaunch window that must keep buffering.
///
/// Undecided and silent both report `isBound == false`, so they are told apart
/// by behaviour: an op emitted while undecided is *held* and drains on a later
/// bind; one emitted while silent is dropped. A real `SyncClient` pair is the
/// witness — a queued envelope is the whole claim.
///
/// The third case is the one #606 added: restore can also answer **unverified** —
/// credentials are on the device and the server could not be reached to confirm
/// them. That is not the local branch. The user id is real, so the provider must
/// build a lifecycle and let it bind, exactly as it does for a verified session;
/// an offline relaunch that fell into the local branch would settle the seam
/// silent and drop the whole session's writes (ADR-0041).
@TestOn('!browser')
library;

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/sync_lifecycle_provider.dart';
import 'package:jeeves/providers/sync_stack_provider.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/device_key_store.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/pending_rotation_store.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:jeeves/sync/sync_lifecycle.dart';
import 'package:jeeves/sync/sync_stack.dart';
import 'package:jeeves/sync/workspace_key_store.dart';

import '../sync/harness/fake_sync_server.dart';
import '../sync/harness/sim_device.dart'
    show DeviceLink, harnessKdfParameters;
import '../test_helpers.dart';

const String _userId = 'provider-user';
const int _nowMs = 1770000000000;
const String _outcomeId = '55555555-5555-4555-8555-555555555555';

/// Session restore that never answers: the seam must keep buffering.
class _PendingAuth extends AuthNotifier {
  @override
  Future<String?> build() => Completer<String?>().future;
}

/// Session restore that answered "no session": the seam must settle silent.
class _AnsweredSignedOutAuth extends AuthNotifier {
  @override
  Future<String?> build() async => null;
}

/// Session restore that answered **unverified**: credentials on the device, the
/// server unreachable. The production `SessionUnverified` arm's two effects — set
/// the real user id, return the stale access token rather than null — with the
/// enrolment gate left out, which this file has no stack to answer anyway.
class _AnsweredUnverifiedAuth extends AuthNotifier {
  @override
  Future<String?> build() async {
    // Suspended first, as the production arm is: it writes the user id only after
    // `restore()` has answered, and a write before the first await trips
    // Riverpod's "no modifying other providers while building" assert.
    await Future<void>.delayed(Duration.zero);
    ref.read(currentUserIdProvider.notifier).setUserId(_userId);
    return 'stale-but-retained-access-token';
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late SyncDatabase database;
  late SyncClient gtdClient;
  late SyncClient preferencesClient;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    database = SyncDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final identity = await MemberIdentity.generate();
    final clock = HlcClock(memberIdHex: identity.memberIdHex, nowMs: () => _nowMs);
    SyncClient clientFor(String workspaceId) => SyncClient(
          workspaceId: workspaceId,
          userId: _userId,
          identity: identity,
          database: database,
          clock: clock,
          reducer: Reducer(database, nowMs: () => _nowMs),
          now: () => DateTime.fromMillisecondsSinceEpoch(_nowMs, isUtc: true),
        );
    gtdClient = clientFor(defaultWorkspaceId(_userId));
    preferencesClient = clientFor(userPreferencesWorkspaceId(_userId));
  });

  /// The shape `GtdDatabase.capturing` produces: the effect is described *inside*
  /// the scope's zone, which is what attributes it to that scope.
  Future<void> emitOutcome(WorkspaceRoutingOpCapture capture) async {
    final scope = capture.beginScope();
    await capture.runInScope(scope, () async {
      capture.write(
        collection: todosCollection,
        entityId: _outcomeId,
        fields: {
          'title': 'Write the thing',
          'created_at': '2026-02-01T09:00:00.000Z',
          'user_id': _userId,
        },
      );
    });
    await capture.commitScope(scope);
  }

  Future<int> outboxCount() async =>
      (await database.select(database.outbox).get()).length;

  test('restore pending leaves the seam undecided — an op is held, not dropped',
      () async {
    final capture = WorkspaceRoutingOpCapture();
    final container = ProviderContainer(overrides: [
      domainOpCaptureProvider.overrideWithValue(capture),
      authTokenProvider.overrideWith(_PendingAuth.new),
    ]);
    addTearDown(container.dispose);

    // The local branch returns null without settling the seam while restore is
    // in flight.
    expect(await container.read(syncLifecycleProvider.future), isNull);
    expect(capture.isBound, isFalse);

    // The op emitted now must have been *buffered*: a later bind drains it.
    await emitOutcome(capture);
    expect(await outboxCount(), 0, reason: 'held while undecided');
    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);
    expect(await outboxCount(), 1, reason: 'the held op drained on bind');
  });

  test('restore answered and still local settles the seam silent — an op is '
      'dropped', () async {
    final capture = WorkspaceRoutingOpCapture();
    final container = ProviderContainer(overrides: [
      domainOpCaptureProvider.overrideWithValue(capture),
      authTokenProvider.overrideWith(_AnsweredSignedOutAuth.new),
    ]);
    addTearDown(container.dispose);

    // Settle auth first, so the provider's first build already sees restore as
    // answered and settles the seam silent immediately.
    expect(await container.read(authTokenProvider.future), isNull);
    expect(await container.read(syncLifecycleProvider.future), isNull);
    expect(capture.isBound, isFalse);

    // Silent, not undecided: the op is dropped, and a later bind has nothing to
    // drain.
    await emitOutcome(capture);
    await capture.bind(
        gtdClient: gtdClient, preferencesClient: preferencesClient);
    expect(await outboxCount(), 0,
        reason: 'a write after the silent decision authors nothing');
  });

  test('restore answered unverified builds a lifecycle and the seam ends bound',
      () async {
    // An enrolled device, relaunched offline, whose silent refresh could not
    // reach the server. The provider must take the *account* branch: a lifecycle
    // is built, it binds from the local reads alone, and the offline write lands
    // in the durable outbox. Fall into the local branch instead and the seam is
    // settled silent — which is #606.
    final capture = WorkspaceRoutingOpCapture();
    final link = DeviceLink(FakeSyncServer().connectAsUser(_userId));
    link.online = false;
    final domain = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
    addTearDown(domain.close);

    final stack = await SyncStack.assemble(
      userId: _userId,
      database: database,
      keyStore: InMemoryDeviceKeyStore(),
      userTransport: link,
      domain: domain,
      nowMs: () => _nowMs,
      workspaceKeys: InMemoryWorkspaceKeyStore(),
      pendingRotations: InMemoryPendingRotationStore(),
      kdfParameters: harnessKdfParameters,
      kdfFloor: harnessKdfParameters,
    );
    // Enrolled before the relaunch, so the lifecycle's own step 1 says "bind"
    // rather than "author nothing". Offline, so nothing after the bind succeeds.
    link.online = true;
    await stack.enrolment.enrolFirstDevice();
    link.online = false;

    final container = ProviderContainer(overrides: [
      domainOpCaptureProvider.overrideWithValue(capture),
      databaseProvider.overrideWithValue(domain),
      syncStackProvider.overrideWith((ref) async => stack),
      authTokenProvider.overrideWith(_AnsweredUnverifiedAuth.new),
    ]);
    addTearDown(container.dispose);

    expect(await container.read(authTokenProvider.future), isNotNull);
    final lifecycle = await container.read(syncLifecycleProvider.future);
    expect(lifecycle, isNotNull,
        reason: 'an unverified session fell into the local-only branch');
    // Join the provider's own un-awaited activation rather than starting a second.
    expect(await lifecycle!.activate(), SyncActivation.syncFailed);
    expect(capture.isBound, isTrue,
        reason: 'the seam was settled silent for a device that is signed in');

    // A delta: the enrolment ceremony's own control ops are in the same outbox.
    final authoredBeforeWrite = await outboxCount();
    await emitOutcome(capture);
    expect(await outboxCount(), authoredBeforeWrite + 1,
        reason: 'the offline write authored nothing into the outbox');
  });
}
