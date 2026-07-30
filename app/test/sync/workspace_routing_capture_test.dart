/// The production capture binding: where an op goes, and when none is authored.
///
/// Routing is asserted by reading the **outbox**, not by watching a spy: the
/// `workspace_id` a queued envelope carries is the whole claim, and a stub client
/// could agree with the router while the store disagreed with both.
///
/// No transport is attached to either client, deliberately. `capture()` authors,
/// queues, reduces and projects locally without one — which is what makes a
/// bound-but-offline device queue correctly rather than lose the write.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart';
import 'package:jeeves/sync/member_identity.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_client.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../test_helpers.dart';

const String _userId = 'routing-user';
const int _nowMs = 1770000000000;

/// A canonical UUID, because `capture()` refuses a non-canonical entity id at the
/// author's own call site (#573).
const String _outcomeId = '55555555-5555-4555-8555-555555555555';

void main() {
  setUpAll(configureSqliteForTests);

  late SyncDatabase database;
  late SyncClient gtdClient;
  late SyncClient preferencesClient;
  late WorkspaceRoutingOpCapture capture;

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
    capture = WorkspaceRoutingOpCapture();
  });

  Future<List<String>> queuedWorkspaceIds() async {
    final rows = await (database.select(database.outbox)
          ..orderBy([(row) => OrderingTerm.asc(row.id)]))
        .get();
    return [for (final row in rows) row.workspaceId];
  }

  Future<void> capturing(void Function() body) async {
    final scope = capture.beginScope();
    body();
    await capture.commitScope(scope);
  }

  void writeOutcome() => capture.write(
        collection: todosCollection,
        entityId: _outcomeId,
        fields: {
          'title': 'Write the thing',
          'created_at': '2026-02-01T09:00:00.000Z',
          'user_id': _userId,
        },
      );

  void writePreference() => capture.write(
        collection: userPreferencesCollection,
        entityId: preferenceEntityId(
          userPreferencesWorkspaceId(_userId),
          'clarify_mode',
        ),
        fields: {
          'key': 'clarify_mode',
          'value': '"oneToOne"',
          'updated_at': '2026-02-01T09:00:00.000Z',
          'user_id': _userId,
        },
      );

  test('unbound, nothing is authored at all', () async {
    await capturing(() {
      writeOutcome();
      writePreference();
    });

    expect(capture.isBound, isFalse);
    expect(await queuedWorkspaceIds(), isEmpty);
    expect(await database.select(database.reducedFields).get(), isEmpty);
  });

  test('a preference goes to the preferences Workspace, everything else to GTD',
      () async {
    capture.bind(gtdClient: gtdClient, preferencesClient: preferencesClient);

    await capturing(writeOutcome);
    await capturing(writePreference);

    expect(await queuedWorkspaceIds(), [
      defaultWorkspaceId(_userId),
      userPreferencesWorkspaceId(_userId),
    ]);
  });

  test('unbinding restores the pre-enrolment state', () async {
    capture.bind(gtdClient: gtdClient, preferencesClient: preferencesClient);
    await capturing(writeOutcome);
    capture.unbind();
    await capturing(writePreference);

    expect(capture.isBound, isFalse);
    expect(await queuedWorkspaceIds(), [defaultWorkspaceId(_userId)]);
  });

  test('the authored-op hook fires once per op, and never for a dropped one',
      () async {
    var authored = 0;
    capture.onOpAuthored = () => authored++;

    await capturing(writeOutcome);
    expect(authored, 0, reason: 'a dropped op is not an authored one');

    capture.bind(gtdClient: gtdClient, preferencesClient: preferencesClient);
    await capturing(() {
      writeOutcome();
      writePreference();
    });
    expect(authored, 2);
  });

  test('buffering, coalescing and rollback are the shared ones', () async {
    capture.bind(gtdClient: gtdClient, preferencesClient: preferencesClient);

    // Three writes to one entity inside one scope are one op.
    await capturing(() {
      writeOutcome();
      capture.write(
        collection: todosCollection,
        entityId: _outcomeId,
        fields: {'notes': 'first'},
      );
      capture.write(
        collection: todosCollection,
        entityId: _outcomeId,
        fields: {'notes': 'second'},
      );
    });
    expect(await queuedWorkspaceIds(), hasLength(1));

    // A rolled-back scope authors nothing, so nothing rolled back is ever signed.
    final rolledBack = capture.beginScope();
    writePreference();
    capture.rollbackScope(rolledBack);
    expect(await queuedWorkspaceIds(), hasLength(1));
  });
}
