/// A whole day of GTD, authored across two devices, converging byte-identical.
///
/// Every act runs through the **real DAOs** — this is not a reducer test with a
/// story attached. Capture, clarify, plan, focus (with an offline window),
/// preference races, and evening shutdown, each writing through the seam that
/// #553 flips on, so what is asserted at the end is that the *application*
/// converges, not just its merge function.
///
/// The four convergence claims, in order of strength:
///
/// 1. A ≡ B on canonical reduced-state bytes;
/// 2. a fresh device C, enrolled at the end, pulls from zero and reaches the
///    same bytes — bootstrap is replay;
/// 3. A rewinding its cursor and re-pulling changes nothing — replay is
///    idempotent, and tombstones never resurrect;
/// 4. every domain projection agrees per collection group, as **full rows** —
///    no column excluded, because every domain column is synced or derived at
///    read time (`todos.time_spent_minutes` was dropped in #604).
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent, RoutingKind;
import 'package:jeeves/sync/envelope.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart' show jeevesWorkspaceNamespace;
import 'package:jeeves/sync/merge_strategy.dart';
import 'package:jeeves/sync/op_payload.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:uuid/uuid.dart';

import '../test_helpers.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const _userId = 'sim-user';
const _snoozeKey = 'nudge_snoozed_until';
const _setMergeKey = 'spec_set_merge';

/// Entity ids are canonical lowercase UUIDs on the wire, so fixtures derive
/// theirs rather than spelling them.
String _id(String label) => const Uuid().v5(jeevesWorkspaceNamespace, 'day/$label');

/// Every collection group's table, and the columns excluded from the row-level
/// comparison — none: every domain column is synced or derived at read time.
const _tables = <String, Set<String>>{
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

void main() {
  setUpAll(configureSqliteForTests);

  test('a full plan → focus → shutdown day converges on every device',
      () async {
    // `set_merge` is provisioned but has no production key, so the harness
    // registers a test key the same way the golden vectors do.
    const strategies = MergeStrategyRegistry(
      preferenceKeyOverrides: {_setMergeKey: setMerge},
    );
    final workspace = await SimWorkspace.create(strategies: strategies);
    addTearDown(workspace.close);
    final a = workspace.a; // phone
    final b = workspace.b; // tablet
    final clock = workspace.clock;

    // --- 1. Capture (A) ------------------------------------------------------
    for (final entry in {
      'capture-1': 'Sort out the quarterly plan',
      'capture-2': 'Quarterly plan: remember the hiring line',
      'capture-3': 'Idle thought, not worth keeping',
    }.entries) {
      clock.advance(1000);
      await a.domain.captureDao.insertCapture(CapturesCompanion(
        id: Value(_id(entry.key)),
        title: Value(entry.value),
        captureSource: Value(entry.key == 'capture-1' ? 'voice' : 'manual'),
        userId: const Value(_userId),
        createdAt: Value(clock.asDateTime),
      ));
    }
    final workTag = await a.domain.tagDao.findOrCreateTag('work', 'context', _userId);
    await a.domain.captureDao.assignTagHint(_id('capture-1'), workTag, _userId);
    // An Outcome that predates the day, used later as a Plan member.
    clock.advance(1000);
    await a.domain.todoDao.insertOutcome(
      id: _id('standing-outcome'),
      title: 'Keep the books tidy',
      userId: _userId,
      now: clock.asDateTime,
    );
    // Two throwaways: one gets soft-trashed, one gets hard-deleted.
    for (final label in ['soft-trashed', 'throwaway']) {
      clock.advance(1000);
      await a.domain.todoDao.insertOutcome(
        id: _id(label),
        title: label,
        userId: _userId,
        now: clock.asDateTime,
      );
    }
    // The throwaway is solely claimed by capture-3, which is what makes the
    // clarification-retraction orphan gate fire later.
    await a.domain.captureDao
        .linkOutcome(_id('capture-3'), _id('throwaway'), _userId, at: clock.asDateTime);
    await workspace.syncAll();

    // --- 2. Clarify (B) ------------------------------------------------------
    clock.advance(1000);
    final outcome = _id('quarterly-plan');
    await b.domain.todoDao.insertOutcome(
      id: outcome,
      title: 'Quarterly plan agreed',
      userId: _userId,
      now: clock.asDateTime,
    );
    await b.domain.todoDao.applyRouting(
      outcome,
      to: RoutingKind.nextAction,
      actionText: 'Draft the three sections',
      now: clock.asDateTime,
    );
    await b.domain.captureDao
        .linkOutcome(_id('capture-1'), outcome, _userId, at: clock.asDateTime);
    await b.domain.captureDao.stampClarified(_id('capture-1'), at: clock.asDateTime);
    // Capture 2 merges into the same Outcome — many-to-many provenance.
    await b.domain.captureDao
        .linkOutcome(_id('capture-2'), outcome, _userId, at: clock.asDateTime);
    await b.domain.captureDao.stampClarified(_id('capture-2'), at: clock.asDateTime);
    // Capture 3 is discarded: a zero-Outcome clarification is still a verdict.
    await b.domain.captureDao.stampClarified(_id('capture-3'), at: clock.asDateTime);
    final contextTag =
        await b.domain.tagDao.findOrCreateTag('deep-work', 'context', _userId);
    await b.domain.tagDao.assignTag(outcome, contextTag, _userId);
    final personTag = await b.domain.tagDao.createPersonTag('Trixy', _userId);
    await b.domain.todoDao
        .setPersonTagsAndStamp(outcome, {personTag}, _userId, now: clock.asDateTime);
    // A planned queue for A to reorder while B is offline.
    await b.domain.actionDao.addPlannedAction(outcome, 'Circulate for comment',
        now: clock.asDateTime);
    await b.domain.actionDao.addPlannedAction(outcome, 'Book the review slot',
        now: clock.asDateTime);
    await workspace.syncAll();

    // --- 3. Plan (A) ---------------------------------------------------------
    clock.advance(1000);
    final sessionId = await a.domain.focusSessionDao.openSession(
      userId: _userId,
      taskIds: [outcome, _id('standing-outcome')],
      now: clock.asDateTime,
    );
    await workspace.syncAll();

    // --- 4. Focus (B), with an offline window --------------------------------
    clock.advance(1000);
    await b.domain.focusSessionDao
        .setCurrentTask(sessionId: sessionId, taskId: outcome, now: clock.asDateTime);
    b.goOffline();

    clock.advance(60000);
    // B finishes the current Action; its open log closes with it.
    await b.domain.actionDao.completeCurrentAction(outcome, now: clock.asDateTime);
    final planned = await b.domain.actionDao.getPlannedActions(outcome);
    final promotedText = planned.first.actionText;
    await b.domain.actionDao
        .promotePlannedAction(planned.first.id, now: clock.asDateTime);
    // B engages an off-Plan Outcome.
    clock.advance(60000);
    await b.domain.focusSessionDao.setCurrentTask(
        sessionId: sessionId, taskId: _id('soft-trashed'), now: clock.asDateTime);
    clock.advance(60000);
    await b.domain.timeLogDao
        .closeLog(taskId: _id('soft-trashed'), now: clock.asDateTime);
    // …and logs time against the Outcome A is about to hard-delete.
    clock.advance(1000);
    await b.domain.timeLogDao
        .openLog(taskId: _id('throwaway'), userId: _userId, now: clock.asDateTime);
    clock.advance(60000);
    await b.domain.timeLogDao.closeLog(taskId: _id('throwaway'), now: clock.asDateTime);

    // Meanwhile A, online, edits the same Outcome's notes and reorders its
    // planned queue — different fields, so field-grain merge keeps both sides.
    clock.advance(1000);
    await a.domain.todoDao.updateFields(outcome, notes: 'Three sections, then review');
    final plannedOnA = await a.domain.actionDao.getPlannedActions(outcome);
    await a.domain.actionDao.reorderPlannedActions(
      outcome,
      plannedOnA.reversed.map((action) => action.id).toList(),
      now: clock.asDateTime,
    );
    // Soft-trash is a plain field write: the entity stays alive, in Trash.
    clock.advance(1000);
    await a.domain.todoDao
        .setIntent(_id('soft-trashed'), Intent.trash, now: clock.asDateTime);
    // The one true hard-delete path: retracting a solely-claimed Outcome
    // through the clarification-retraction orphan gate.
    clock.advance(1000);
    await a.domain.captureDao.unlinkOutcome(_id('capture-3'), _id('throwaway'));
    expect(await a.domain.captureDao.captureIdsForOutcome(_id('throwaway')), isEmpty);
    await a.domain.todoDao.deleteOutcome(_id('throwaway'));
    await a.syncIfOnline();

    // B reconnects.
    b.goOnline();
    clock.advance(1000);
    await workspace.syncAll();

    // B restores the soft-trashed Outcome out of Trash — the restore direction
    // is `applyRouting`, the trash direction was `setIntent`.
    clock.advance(1000);
    await b.domain.todoDao.applyRouting(_id('soft-trashed'),
        to: RoutingKind.nextAction, now: clock.asDateTime);
    await workspace.syncAll();

    // --- 5. Preference races -------------------------------------------------
    // Concurrent snooze floors: A's later *value* on the older clock wins.
    await a.preferences.set(_snoozeKey, '"2026-08-01T00:00:00.000Z"');
    await b.preferences.set(_snoozeKey, '"2026-07-29T00:00:00.000Z"');
    await workspace.syncAll();
    for (final device in [a, b]) {
      expect(await device.preferences.get(_snoozeKey), '"2026-08-01T00:00:00.000Z"',
          reason: '${device.label} regressed the snooze floor');
    }
    // B clears, A re-snoozes later — the re-snooze survives the clear.
    clock.advance(1000);
    await b.preferences.delete(_snoozeKey);
    await workspace.syncAll();
    clock.advance(1000);
    await a.preferences.set(_snoozeKey, '"2026-09-01T00:00:00.000Z"');
    await workspace.syncAll();
    for (final device in [a, b]) {
      expect(await device.preferences.get(_snoozeKey), '"2026-09-01T00:00:00.000Z"');
    }
    // Concurrent additions to a set-merge key both survive.
    await a.preferences.set(_setMergeKey, '["alpha"]');
    await b.preferences.set(_setMergeKey, '["beta"]');
    await workspace.syncAll();
    for (final device in [a, b]) {
      expect(await device.preferences.get(_setMergeKey), '["alpha","beta"]');
    }

    // --- 6. Shutdown (A) -----------------------------------------------------
    clock.advance(1000);
    await a.domain.focusSessionDao.reviewAndCloseSession(
      sessionId: sessionId,
      dispositions: {
        outcome: 'rollover',
        // A Plan member deferred: the Review writes intent='maybe' on `todos`.
        _id('standing-outcome'): 'maybe',
        // B's off-Plan engagement earns a Disposition in the separate home,
        // and 'leave' writes nothing to the Outcome — so the restore holds.
        _id('soft-trashed'): 'leave',
      },
      now: clock.asDateTime,
    );
    await workspace.syncAll();

    // --- 7. Convergence ------------------------------------------------------
    final bytesA = await canonicalReducedState(a.database);
    expect(await canonicalReducedState(b.database), bytesA,
        reason: 'A and B disagree on reduced state');

    // A fresh device enrolling at the end reaches the same bytes: bootstrap is
    // replay, and replay is the only thing it does.
    final c = await SimDevice.create(
      label: 'C',
      userId: _userId,
      server: workspace.server,
      clock: clock,
      memberId: const Uuid().v5(jeevesWorkspaceNamespace, 'sim/device/2'),
      seed: Uint8List.fromList(
        List<int>.generate(32, (byte) => (byte + 2 * 31 + 1) % 256),
      ),
      strategies: strategies,
      // A later device enrols with the passphrase and nothing else — the Root in
      // the escrow slot is A's, and minting a fresh one would be refused. This
      // is also what makes the replay below a *bootstrap*: C has to verify every
      // author's registration off the log before it can reduce their content.
      passphrase: workspace.passphrase,
    );
    addTearDown(c.close);
    await c.sync();
    expect(await canonicalReducedState(c.database), bytesA,
        reason: 'a fresh device did not reach the same state by replay');

    // Replaying the whole log into an already-populated device changes nothing.
    await a.client.resetCursorForReplay();
    await a.sync();
    expect(await canonicalReducedState(a.database), bytesA,
        reason: 'replay was not idempotent');

    // Reverse order, straight through the reducer: order-independence at
    // scenario scale rather than at vector scale.
    final reversed = SyncDatabase(NativeDatabase.memory());
    addTearDown(reversed.close);
    final reversedReducer =
        Reducer(reversed, nowMs: () => clock.nowMs, strategies: strategies);
    final log = await a.database.select(a.database.opLog).get();
    for (final row in log.reversed) {
      // Refused ops stay in the log as evidence, never applied. Replaying one
      // here would compare a state no device holds — and would do it for a
      // reason that has nothing to do with order-independence.
      if (row.refusedReason != null) continue;
      final parts = splitEnvelope(row.envelope);
      final header = OpHeader.parse(parts.header);
      // Control ops share the log but carry no content, so they reduce to
      // nothing — the same split the receive pipeline makes. Order-independence
      // is a claim about content, and a MemberRegister has no fields to merge.
      if (header.opClass != opClassContent) continue;
      await reversedReducer.apply(
        OpPayload.decode(parseBody(parts.body)),
        authorMemberIdHex: memberIdToHex(header.authorMemberId),
      );
    }
    expect(await canonicalReducedState(reversed), bytesA,
        reason: 'reduction is not order-independent at scenario scale');

    // Every domain projection agrees, as full rows.
    for (final entry in _tables.entries) {
      final rowsA =
          await domainRows(a.domain, entry.key, exclude: entry.value);
      for (final device in [b, c]) {
        expect(
          await domainRows(device.domain, entry.key, exclude: entry.value),
          rowsA,
          reason: '${entry.key} differs on ${device.label}',
        );
      }
    }

    // The domain facts the day was supposed to produce.
    for (final device in [a, b, c]) {
      final store = device.domain;
      final merged = await store.todoDao.getTodo(outcome);
      expect(merged!.notes, 'Three sections, then review',
          reason: "A's notes edit was lost on ${device.label}");
      final current = await store.actionDao.getCurrentAction(outcome);
      expect(current!.actionText, promotedText,
          reason: "B's promote was lost on ${device.label}");

      // Soft-trash destroyed nothing, and the restore landed. Its Disposition
      // was 'leave', which writes nothing to the Outcome, so it stays on Next.
      final restored = await store.todoDao.getTodo(_id('soft-trashed'));
      expect(restored!.intent, 'next');
      // The deferred Plan member did move.
      final deferred = await store.todoDao.getTodo(_id('standing-outcome'));
      expect(deferred!.intent, 'maybe');
      final logsOnRestored = await (store.select(store.timeLogs)
            ..where((log) => log.taskId.equals(_id('soft-trashed'))))
          .get();
      expect(logsOnRestored, isNotEmpty,
          reason: "B's offline stint on the trashed Outcome was destroyed");

      // The hard-deleted Outcome is tombstone-dead everywhere, and the TimeLog
      // against it survives with Outcome-grain attribution — *elsewhere*.
      expect(await store.todoDao.getTodo(_id('throwaway')), isNull);
      final orphanLogs = await (store.select(store.timeLogs)
            ..where((log) => log.taskId.equals(_id('throwaway'))))
          .get();
      expect(orphanLogs, hasLength(1));
      expect(orphanLogs.single.actionId, isNull);

      // Provenance survived the merge: two Captures claim one Outcome.
      expect(await store.captureDao.captureIdsForOutcome(outcome), hasLength(2));

      // Shutdown's dispositions landed in both homes.
      final rollover =
          await store.focusSessionDao.getLastClosedSessionRolloverTaskIds();
      expect(rollover, contains(outcome));
    }
  });
}
