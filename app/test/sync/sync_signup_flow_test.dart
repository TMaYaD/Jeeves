/// Signing up for sync starts syncing — the whole journey, no tooling step.
///
/// The claim under test is the product one: a user who has worked offline enrols,
/// and *without touching anything else* their store is on the log and a second
/// device converges to it. Everything runs through the real DAOs, the real
/// `SyncStack`, the real `EnrolmentService` and the real lifecycle; only the
/// platform doubles (store, key store, transport, clock) are the harness's.
///
/// Three claims, in order of strength:
///
/// 1. **An un-enrolled device authors nothing at all.** Asserted first and
///    directly, because it is the regression that would be invisible otherwise: a
///    capture seam bound too early turns every offline user into an author with
///    no log to author into.
/// 2. **Enrolment is the trigger.** One `activate()` — what the enrolment
///    outcome and the app's own launch both call — and the store is authored,
///    flushed and marked.
/// 3. **A second device converges, and re-authors nothing.** B's own initial
///    upload walks a projector-fed store and skips every entity, which is the
///    #587 idempotence re-verified in the new seam (AC-4).
@TestOn('!browser')
library;

import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/sync/envelope.dart' show opClassContent;
import 'package:jeeves/sync/ids.dart'
    show jeevesWorkspaceNamespace, userPreferencesWorkspaceId;
import 'package:jeeves/sync/sync_lifecycle.dart';
import 'package:uuid/uuid.dart';

import '../test_helpers.dart';
import 'harness/fake_sync_server.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart' show FakeClock;
import 'harness/sim_workspace.dart' show simulationStartWallMs;
import 'harness/stack_phone.dart';

const String _userId = 'signup-user';

/// Entity ids are canonical lowercase UUIDs on the wire, so fixtures derive
/// theirs rather than spelling them.
String _id(String label) =>
    const Uuid().v5(jeevesWorkspaceNamespace, 'signup/$label');

/// Every collection group's table, and the columns excluded from the row-level
/// comparison — none: every domain column is synced or derived at read time
/// (`todos.time_spent_minutes` was dropped in #604).
const Map<String, Set<String>> _tables = {
  'todos': {},
  'actions': {},
  'tags': {},
  'todo_tags': {},
  'captures': {},
  'capture_outcomes': {},
  'capture_tags': {},
  'focus_sessions': {},
  'focus_session_tasks': {},
  'focus_session_dispositions': {},
  'time_logs': {},
  'user_preferences': {},
};

/// A day's worth of offline GTD, written through the DAOs — the store the user
/// arrives at enrolment with.
Future<void> _seedOfflineWork(GtdDatabase domain, FakeClock clock) async {
  clock.advance(1000);
  await domain.captureDao.insertCapture(CapturesCompanion(
    id: Value(_id('capture-1')),
    title: const Value('Sort out the quarterly plan'),
    captureSource: const Value('voice'),
    userId: const Value(_userId),
    createdAt: Value(clock.asDateTime),
  ));
  final workTag = await domain.tagDao.findOrCreateTag('work', 'context', _userId);
  await domain.captureDao.assignTagHint(_id('capture-1'), workTag, _userId);

  clock.advance(1000);
  final outcome = _id('quarterly-plan');
  await domain.todoDao.insertOutcome(
    id: outcome,
    title: 'Quarterly plan agreed',
    userId: _userId,
    now: clock.asDateTime,
  );
  await domain.todoDao.applyRouting(
    outcome,
    to: RoutingKind.nextAction,
    actionText: 'Draft the three sections',
    now: clock.asDateTime,
  );
  await domain.tagDao.assignTag(outcome, workTag, _userId);
  await domain.captureDao
      .linkOutcome(_id('capture-1'), outcome, _userId, at: clock.asDateTime);
  await domain.captureDao.stampClarified(_id('capture-1'), at: clock.asDateTime);

  // Through the DAO, so the preference travels the capture seam rather than
  // `PreferencesStore`: the routing binding is the only thing that can put it in
  // the Workspace its entity id derives from.
  clock.advance(1000);
  await domain.userPreferencesDao.set(_userId, 'clarify_mode', '"oneToOne"');
}

int _contentOpCount(FakeSyncServer server, {String? workspaceId}) => server
    .storedOps
    .where((op) => op.header?.opClass == opClassContent)
    .where((op) => workspaceId == null || op.workspaceId == workspaceId)
    .length;

void main() {
  setUpAll(configureSqliteForTests);

  late FakeSyncServer server;
  late FakeClock clock;

  setUp(() {
    server = FakeSyncServer();
    clock = FakeClock(simulationStartWallMs);
  });

  test('enrolment authors the offline store, and a second device converges',
      () async {
    final a = await StackPhone.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
    );
    addTearDown(a.close);

    // --- 1. a day offline, un-enrolled --------------------------------------
    await _seedOfflineWork(a.domain, clock);

    // AC-3, asserted rather than assumed: the seam is bound to nothing, so the
    // whole day describes its effects into a void.
    expect(await a.syncStore.select(a.syncStore.outbox).get(), isEmpty);
    expect(await a.syncStore.select(a.syncStore.opLog).get(), isEmpty);
    expect(
      await canonicalReducedState(a.syncStore),
      '{"collections":{},"tombstones":{}}',
      reason: 'an un-enrolled device authored something',
    );
    expect(a.capture.isBound, isFalse);

    final domainRowsBeforeEnrolment = <String, List<Map<String, Object?>>>{
      for (final entry in _tables.entries)
        entry.key: await domainRows(a.domain, entry.key,
            exclude: entry.value, orderBy: 'id'),
    };

    // --- 2. sign up for sync -------------------------------------------------
    final passphrase = (await a.enrolAsFirstDevice()).passphrase;

    // The one call the enrolment surface makes, and the app makes at launch.
    expect(await a.activate(), SyncActivation.active);

    // The store is on the log and the queue is drained — no further interaction.
    expect(a.capture.isBound, isTrue);
    expect((await a.stack.defaultClient.health()).pendingOpCount, 0);
    expect((await (await a.preferencesClient).health()).pendingOpCount, 0);
    final authoredOpCount = _contentOpCount(server);
    expect(authoredOpCount, greaterThan(0));
    // The preference landed in the preferences Workspace, not the GTD one: its
    // entity id is `uuid5(preferences_workspace_id, key)`, so a mis-routed op
    // would be an id nobody's log derives.
    expect(
      _contentOpCount(server,
          workspaceId: userPreferencesWorkspaceId(_userId)),
      1,
    );

    final marker = await InitialUploadMarkerStore(a.syncStore).read(_userId);
    expect(marker, isNotNull);
    expect(marker!.completedAtUtcMs, clock.nowMs);

    // The walk read the rows and the projector wrote them back; the round trip
    // is lossless, so A's own store is untouched by its own upload.
    for (final entry in _tables.entries) {
      expect(
        await domainRows(a.domain, entry.key,
            exclude: entry.value, orderBy: 'id'),
        domainRowsBeforeEnrolment[entry.key],
        reason: 'A\'s ${entry.key} changed under its own initial upload',
      );
    }

    // --- 3. a second device, with the passphrase alone -----------------------
    final b = await StackPhone.create(
      label: 'B',
      userId: _userId,
      server: server,
      clock: clock,
    );
    addTearDown(b.close);
    await b.enrolWithPassphrase(passphrase);
    expect(await b.activate(), SyncActivation.active);

    // B's own initial upload walked a projector-fed store and had nothing to do.
    expect(
      _contentOpCount(server),
      authoredOpCount,
      reason: 'B re-authored data the log already held',
    );
    expect(
      await InitialUploadMarkerStore(b.syncStore).read(_userId),
      isNotNull,
    );

    // Byte-identical reduced state, then the domain read model B never wrote by
    // hand — the projector fed all of it.
    expect(
      await canonicalReducedState(b.syncStore),
      await canonicalReducedState(a.syncStore),
    );
    for (final entry in _tables.entries) {
      expect(
        await domainRows(b.domain, entry.key,
            exclude: entry.value, orderBy: 'id'),
        await domainRows(a.domain, entry.key,
            exclude: entry.value, orderBy: 'id'),
        reason: entry.key,
      );
    }

    // --- 4. and from here on, writes sync themselves -------------------------
    clock.advance(1000);
    await b.domain.todoDao.insertOutcome(
      id: _id('written-while-enrolled'),
      title: 'Book the review slot',
      userId: _userId,
      now: clock.asDateTime,
    );
    // The debounced flusher, without waiting out its timer.
    await b.lifecycle!.flushOutboxNow();
    await a.stack.defaultClient.sync();
    expect(
      await domainRows(a.domain, 'todos'),
      await domainRows(b.domain, 'todos'),
    );
  });

  test('an interrupted upload resumes without re-authoring', () async {
    final a = await StackPhone.create(
      label: 'A',
      userId: _userId,
      server: server,
      clock: clock,
    );
    addTearDown(a.close);
    // Legacy rows — data that predates authoring (PowerSync-era).
    // Settle the seam silent so the seed lands in the domain store without being
    // buffered: the **initial upload** is what authors these, which is the path
    // this test is about. (A captured pre-enrolment write would instead be
    // drained at bind and flushed at the first sync — a different path.)
    a.capture.unbind();
    await _seedOfflineWork(a.domain, clock);
    await a.enrolAsFirstDevice();

    // The upload's POST lands and the response is lost — indistinguishable, from
    // here, from one that never arrived. The walk authored every op; the post
    // did not confirm.
    a.link.dropPostResponse = true;
    expect(await a.activate(), SyncActivation.uploadIncomplete);
    expect(
      await InitialUploadMarkerStore(a.syncStore).read(_userId),
      isNull,
      reason: 'an incomplete pass must not be marked complete',
    );
    expect(_contentOpCount(server), greaterThan(0));

    // The next sync. The diff skip is what makes it free: every entity is
    // already in reduced state, so the pass authors nothing and completes.
    expect(await a.activate(), SyncActivation.active);
    final marker = await InitialUploadMarkerStore(a.syncStore).read(_userId);
    expect(marker, isNotNull);
    final report = jsonDecode(marker!.lastReportJson!) as Map<String, Object?>;
    final planned = report['planned_entity_count'];

    // The resumed pass authored nothing and skipped everything — the diff skip
    // reading the target rather than remembering the run.
    expect(report['authored_op_count'], 0);
    expect(report['skipped_entity_count'], planned);
    // And the server holds exactly one content op per planned entity: the ops
    // the first pass authored, plus the one whose POST the interruption left
    // queued, and not a single duplicate.
    expect(
      _contentOpCount(server),
      planned,
      reason: 'the resume re-authored what the first pass had already authored',
    );
  });
}
