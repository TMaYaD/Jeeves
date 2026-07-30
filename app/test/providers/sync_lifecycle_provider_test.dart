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
@TestOn('!browser')
library;

import 'dart:async';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/sync_lifecycle_provider.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';

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

  Future<void> emitOutcome(WorkspaceRoutingOpCapture capture) async {
    final scope = capture.beginScope();
    capture.write(
      collection: todosCollection,
      entityId: _outcomeId,
      fields: {
        'title': 'Write the thing',
        'created_at': '2026-02-01T09:00:00.000Z',
        'user_id': _userId,
      },
    );
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
}
