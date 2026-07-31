/// The capture contract every DAO write path owes the op log.
///
/// This is the contract #553's flip relies on: at the flip the seam stops being
/// a no-op, and any write path that never described its effect becomes a write
/// that silently does not sync. So the assertion here is per write path, driven
/// through the **real DAOs** on a real store, against a recording seam — no
/// mocks, and no way for a path to pass by not being exercised.
///
/// It also pins where the log is deliberately *wider* than the local write:
/// `deleteOutcome`'s enumerated cascade set (§ 2.4).
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/capture_dao.dart'
    show captureOutcomeIdFor, captureTagIdFor;
import 'package:jeeves/database/daos/focus_session_dao.dart'
    show focusSessionDispositionIdFor;
import 'package:jeeves/database/daos/tag_dao.dart' show todoTagIdFor;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent, RoutingKind;
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';
import 'package:jeeves/sync/ids.dart'
    show focusSessionTaskIdFor, preferenceEntityId, userPreferencesWorkspaceId;

import '../test_helpers.dart';

const _userId = 'test-user';
final _ts = DateTime.utc(2026, 7, 28, 9);

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingDomainOpCapture capture;
  late GtdDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    capture = RecordingDomainOpCapture();
    db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
  });
  tearDown(() async => db.close());

  Future<String> seedOutcome({String id = 'outcome-1', String title = 'Ship it'}) async {
    await db.todoDao.insertOutcome(
      id: id,
      title: title,
      userId: _userId,
      now: _ts,
    );
    capture.clear();
    return id;
  }

  CapturedOp only(String collection) {
    final ops = capture.forCollection(collection);
    expect(ops, hasLength(1), reason: 'expected exactly one $collection op');
    return ops.single;
  }

  group('todo_dao', () {
    test('insertOutcome asserts the whole row', () async {
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Ship it', userId: _userId, now: _ts);
      final op = only(todosCollection);
      expect(op.entityId, 'o1');
      expect(op.tombstone, isFalse);
      expect(op.fields['title'], 'Ship it');
      expect(op.fields['user_id'], _userId);
      expect(op.fields['created_at'], '2026-07-28T09:00:00.000Z');
      expect(op.fields['intent'], 'next');
      expect(op.fields['clarified'], isTrue);
      // Exactly the synced columns — no more, no less — so a peer can build the
      // row and nothing off-contract slips onto the wire.
      final expected = collectionCodecs[todosCollection]!.columns.keys.toSet();
      expect(op.fields.keys.toSet(), expected);
    });

    test('updateFields captures only the columns the edit touched', () async {
      final id = await seedOutcome();
      await db.todoDao.updateFields(id, notes: 'context');
      final op = only(todosCollection);
      expect(op.fields.keys, containsAll(['notes', 'updated_at', 'last_clarified_at']));
      expect(op.fields.containsKey('title'), isFalse);
    });

    test('setIntent(trash) is a field write on a live entity, not a delete', () async {
      final id = await seedOutcome();
      await db.todoDao.setIntent(id, Intent.trash, now: _ts);
      final op = only(todosCollection);
      expect(op.tombstone, isFalse);
      expect(op.fields['intent'], 'trash');
    });

    test('applyRouting restores out of Trash on the same seam', () async {
      final id = await seedOutcome();
      await db.todoDao.setIntent(id, Intent.trash, now: _ts);
      capture.clear();
      await db.todoDao.applyRouting(id, to: RoutingKind.nextAction, now: _ts);
      final op = only(todosCollection);
      expect(op.fields['intent'], 'next');
      expect(op.fields['done_at'], isNull);
    });

    test('markDone captures done_at and the Action completion', () async {
      final id = await seedOutcome();
      await db.todoDao.setCurrentActionText(id, 'Draft the memo', now: _ts);
      capture.clear();
      await db.todoDao.markDone(id, now: _ts);
      expect(only(todosCollection).fields['done_at'], isNotNull);
      expect(only(actionsCollection).fields['role'], 'done');
    });

    test('rescheduleTask and stampLastClarifiedAt each capture', () async {
      final id = await seedOutcome();
      await db.todoDao.rescheduleTask(id, DateTime.utc(2026, 8, 1), now: _ts);
      expect(only(todosCollection).fields['due_date'], '2026-08-01T00:00:00.000Z');
      capture.clear();
      await db.todoDao.stampLastClarifiedAt(id, now: _ts);
      expect(only(todosCollection).fields.keys,
          containsAll(['last_clarified_at', 'updated_at']));
    });

    test('setPersonTagsForTodo asserts adds and tombstones removals', () async {
      final id = await seedOutcome();
      final alice = await db.tagDao.createPersonTag('Alice', _userId);
      final bob = await db.tagDao.createPersonTag('Bob', _userId);
      await db.todoDao.setPersonTagsForTodo(id, {alice}, _userId);
      capture.clear();
      await db.todoDao.setPersonTagsAndStamp(id, {bob}, _userId, now: _ts);
      final junctions = {
        for (final op in capture.forCollection(todoTagsCollection))
          op.entityId: op.tombstone,
      };
      expect(junctions[todoTagIdFor(id, alice)], isTrue);
      expect(junctions[todoTagIdFor(id, bob)], isFalse);
    });

    test('setCurrentActionText stamps the Outcome and writes the Action', () async {
      final id = await seedOutcome();
      await db.todoDao.setCurrentActionText(id, 'Draft the memo', now: _ts);
      expect(only(todosCollection).fields.containsKey('last_clarified_at'), isTrue);
      expect(only(actionsCollection).fields['text'], 'Draft the memo');
    });

    test('deleteOutcome enumerates the cascade the server used to run', () async {
      final id = await seedOutcome();
      final tag = await db.tagDao.findOrCreateTag('errand', 'context', _userId);
      await db.tagDao.assignTag(id, tag, _userId);
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('a thought'),
        userId: const Value(_userId),
        createdAt: Value(_ts),
      ));
      await db.captureDao.linkOutcome('c1', id, _userId, at: _ts);
      await db.todoDao.setCurrentActionText(id, 'Draft the memo', now: _ts);
      await db.timeLogDao.openLog(taskId: id, userId: _userId, now: _ts);
      final logId = (await db.select(db.timeLogs).getSingle()).id;
      final actionId = (await db.select(db.actions).getSingle()).id;
      capture.clear();

      await db.todoDao.deleteOutcome(id);

      final byKey = {for (final op in capture.recorded) '${op.collection}/${op.entityId}': op};
      // Everything the server's ON DELETE CASCADE / SET NULL used to do, now
      // enumerated at authoring time.
      expect(byKey['$todosCollection/$id']!.tombstone, isTrue);
      expect(byKey['$actionsCollection/$actionId']!.tombstone, isTrue);
      expect(byKey['$todoTagsCollection/${todoTagIdFor(id, tag)}']!.tombstone, isTrue);
      expect(
        byKey['$captureOutcomesCollection/${captureOutcomeIdFor('c1', id)}']!.tombstone,
        isTrue,
      );
      // SET NULL, never a delete: time data survives its Outcome.
      final logOp = byKey['$timeLogsCollection/$logId']!;
      expect(logOp.tombstone, isFalse);
      expect(logOp.fields, {'action_id': null});
    });

    test('deleteOutcome authors nothing when the Outcome is already gone',
        () async {
      // The contract the method's docstring states — "0 if [id] was already
      // gone" — is a claim about the log too, not only the return value. A
      // snapshot callsite can hold an id this store never had (issue #600); a
      // tombstone authored for it is a delete a peer that *does* hold the
      // Outcome would apply.
      final removed = await db.todoDao.deleteOutcome('never-existed');

      expect(removed, 0);
      expect(capture.recorded, isEmpty,
          reason: 'a delete that removed nothing must assert nothing');
    });

    test('deleteOutcome leaves a dangling junction alone', () async {
      // Reachable without a typo: the projector never enforces referential
      // existence, so a pulled `deleteOutcome` can take the `todos` row while a
      // `todo_tags` row for the same id is still on its way. The cascade
      // enumerates by `todo_id`, so an ungated one tombstones junctions it never
      // established — and `capture_outcomes` links the *surviving* Capture holds.
      final id = await seedOutcome();
      final tag = await db.tagDao.findOrCreateTag('errand', 'context', _userId);
      await db.tagDao.assignTag(id, tag, _userId);
      await db.customStatement('DELETE FROM todos WHERE id = ?', [id]);
      final danglingBefore = await (db.select(db.todoTags)
            ..where((row) => row.todoId.equals(id)))
          .get();
      expect(danglingBefore, hasLength(1),
          reason: 'the raw parent delete must leave the junction dangling — '
              'otherwise this is the already-gone case, not the regression');
      capture.clear();

      final removed = await db.todoDao.deleteOutcome(id);

      expect(removed, 0);
      expect(capture.recorded, isEmpty,
          reason: 'the junction is not this absent Outcome\'s to tombstone');
      final danglingAfter = await (db.select(db.todoTags)
            ..where((row) => row.todoId.equals(id)))
          .get();
      expect(danglingAfter, hasLength(1),
          reason: 'the surviving junction is left untouched');
    });
  });

  group('action_dao', () {
    test('every planned-queue primitive captures', () async {
      final id = await seedOutcome();
      await db.actionDao.addPlannedAction(id, 'first', now: _ts);
      final planned = only(actionsCollection);
      expect(planned.fields['role'], 'planned');
      expect(planned.fields['position'], 0);
      final firstId = planned.entityId;
      capture.clear();

      await db.actionDao.addPlannedAction(id, 'second', now: _ts);
      final secondId = capture
          .forCollection(actionsCollection)
          .firstWhere((op) => op.fields['text'] == 'second')
          .entityId;
      capture.clear();

      await db.actionDao.reorderPlannedActions(id, [secondId, firstId], now: _ts);
      expect(
        {for (final op in capture.forCollection(actionsCollection)) op.entityId},
        {firstId, secondId},
      );
      capture.clear();

      await db.actionDao.promotePlannedAction(secondId, now: _ts);
      expect(
        capture
            .forCollection(actionsCollection)
            .firstWhere((op) => op.entityId == secondId)
            .fields['role'],
        'current',
      );
      capture.clear();

      await db.actionDao.supersedeAndPromote(firstId, now: _ts);
      final roles = {
        for (final op in capture.forCollection(actionsCollection))
          op.entityId: op.fields['role'],
      };
      expect(roles[secondId], 'superseded');
      expect(roles[firstId], 'current');
      capture.clear();

      await db.actionDao.demoteCurrentAction(firstId, now: _ts);
      expect(only(actionsCollection).fields['role'], 'planned');
      capture.clear();

      await db.actionDao.removePlannedAction(firstId, now: _ts);
      // A hard delete on the log is a tombstone, never row absence.
      expect(
        capture
            .forCollection(actionsCollection)
            .firstWhere((op) => op.entityId == firstId)
            .tombstone,
        isTrue,
      );
    });

    test('editAction mirrors metadata onto the Outcome on the same seam', () async {
      final id = await seedOutcome();
      await db.actionDao.setCurrentAction(id, 'Draft', now: _ts);
      final actionId = only(actionsCollection).entityId;
      capture.clear();
      await db.actionDao.editAction(actionId, energyLevel: 'low', now: _ts);
      expect(only(actionsCollection).fields['energy_level'], 'low');
      expect(only(todosCollection).fields['energy_level'], 'low');
    });

    test('supersede closes the open log and reopens against the successor',
        () async {
      final id = await seedOutcome();
      await db.actionDao.setCurrentAction(id, 'Draft', now: _ts);
      await db.timeLogDao.openLog(taskId: id, userId: _userId, now: _ts);
      final openLogId = (await db.select(db.timeLogs).getSingle()).id;
      capture.clear();

      await db.actionDao
          .supersedeCurrentAction(id, newActionText: 'Rewrite', now: _ts);
      final logOps = {
        for (final op in capture.forCollection(timeLogsCollection)) op.entityId: op,
      };
      expect(logOps[openLogId]!.fields['ended_at'], isNotNull);
      final reopened = logOps.values.firstWhere((op) => op.entityId != openLogId);
      expect(reopened.fields['ended_at'], isNull);
      expect(reopened.fields['task_id'], id);
    });
  });

  group('tag_dao', () {
    test('creation asserts the row; a colour edit asserts only the colour',
        () async {
      final tagId = await db.tagDao.findOrCreateTag('errand', 'context', _userId);
      expect(only(tagsCollection).fields.keys.toSet(),
          collectionCodecs[tagsCollection]!.columns.keys.toSet());
      capture.clear();
      await db.tagDao.updateColor(tagId, '#123456');
      expect(only(tagsCollection).fields, {'color': '#123456'});
    });

    test('merge tombstones the source tag and every junction it held', () async {
      final outcome = await seedOutcome();
      final source = await db.tagDao.findOrCreateTag('a', 'context', _userId);
      final target = await db.tagDao.findOrCreateTag('b', 'context', _userId);
      await db.tagDao.assignTag(outcome, source, _userId);
      capture.clear();

      await db.tagDao.merge(source, target);
      final byKey = {
        for (final op in capture.recorded) '${op.collection}/${op.entityId}': op,
      };
      expect(byKey['$tagsCollection/$source']!.tombstone, isTrue);
      expect(
        byKey['$todoTagsCollection/${todoTagIdFor(outcome, source)}']!.tombstone,
        isTrue,
      );
      expect(
        byKey['$todoTagsCollection/${todoTagIdFor(outcome, target)}']!.tombstone,
        isFalse,
      );
    });

    test('enforceSingleProject tombstones the displaced project link', () async {
      final outcome = await seedOutcome();
      final first = await db.tagDao.findOrCreateTag('p1', 'project', _userId);
      final second = await db.tagDao.findOrCreateTag('p2', 'project', _userId);
      await db.tagDao.enforceSingleProject(outcome, _userId, first);
      capture.clear();
      await db.tagDao.enforceSingleProject(outcome, _userId, second);
      final byKey = {
        for (final op in capture.forCollection(todoTagsCollection))
          op.entityId: op.tombstone,
      };
      expect(byKey[todoTagIdFor(outcome, first)], isTrue);
      expect(byKey[todoTagIdFor(outcome, second)], isFalse);
    });
  });

  group('capture_dao', () {
    Future<void> seedCapture() async {
      await db.captureDao.insertCapture(CapturesCompanion(
        id: const Value('c1'),
        title: const Value('a thought'),
        userId: const Value(_userId),
        createdAt: Value(_ts),
      ));
    }

    test('insertCapture asserts the whole row', () async {
      await seedCapture();
      expect(only(capturesCollection).fields.keys.toSet(),
          collectionCodecs[capturesCollection]!.columns.keys.toSet());
    });

    test('stamp is idempotent on the wire; unstamp is a null field write',
        () async {
      await seedCapture();
      capture.clear();
      await db.captureDao.stampClarified('c1', at: _ts);
      expect(only(capturesCollection).fields['clarified_at'], isNotNull);
      capture.clear();
      // A second stamp moves nothing, so it authors nothing.
      await db.captureDao.stampClarified('c1', at: _ts.add(const Duration(hours: 1)));
      expect(capture.forCollection(capturesCollection), isEmpty);
      capture.clear();
      await db.captureDao.unstampClarified('c1');
      final op = only(capturesCollection);
      expect(op.tombstone, isFalse, reason: 'the Capture is alive, back in the Inbox');
      expect(op.fields['clarified_at'], isNull);
    });

    test('link/unlink and hints are junction writes and tombstones', () async {
      final outcome = await seedOutcome();
      await seedCapture();
      final tag = await db.tagDao.findOrCreateTag('errand', 'context', _userId);
      capture.clear();

      await db.captureDao.linkOutcome('c1', outcome, _userId, at: _ts);
      expect(only(captureOutcomesCollection).entityId,
          captureOutcomeIdFor('c1', outcome));
      capture.clear();

      await db.captureDao.unlinkOutcome('c1', outcome);
      expect(only(captureOutcomesCollection).tombstone, isTrue);
      capture.clear();

      await db.captureDao.assignTagHint('c1', tag, _userId);
      expect(only(captureTagsCollection).entityId, captureTagIdFor('c1', tag));
      capture.clear();

      await db.captureDao.removeTagHint('c1', tag);
      expect(only(captureTagsCollection).tombstone, isTrue);
      capture.clear();

      // A delete that matches nothing describes no effect: authoring the
      // tombstone anyway would let an idempotent call bury a link another
      // device created concurrently under the same deterministic id.
      await db.captureDao.removeTagHint('c1', tag);
      await db.captureDao.unlinkOutcome('c1', outcome);
      expect(capture.recorded, isEmpty);
    });
  });

  group('focus_session_dao', () {
    test('openSession captures the session and pair-derived Plan rows', () async {
      final outcome = await seedOutcome();
      final sessionId = await db.focusSessionDao
          .openSession(userId: _userId, taskIds: [outcome], now: _ts);
      expect(only(focusSessionsCollection).entityId, sessionId);
      final planOp = only(focusSessionTasksCollection);
      // The entity id is the pair derivation, not the random local `id`.
      expect(planOp.entityId, focusSessionTaskIdFor(sessionId, outcome));
      expect(planOp.fields['position'], 0);
    });

    test('setCurrentTask moves the pointer and opens a log', () async {
      final outcome = await seedOutcome();
      final sessionId = await db.focusSessionDao
          .openSession(userId: _userId, taskIds: [outcome], now: _ts);
      capture.clear();
      await db.focusSessionDao
          .setCurrentTask(sessionId: sessionId, taskId: outcome, now: _ts);
      expect(only(focusSessionsCollection).fields['current_task_id'], outcome);
      expect(only(timeLogsCollection).fields['focus_session_id'], sessionId);
    });

    test('reviewAndCloseSession fans out across both Disposition homes',
        () async {
      final planned = await seedOutcome(id: 'planned-1', title: 'Planned');
      await db.todoDao
          .insertOutcome(id: 'offplan-1', title: 'Off-Plan', userId: _userId, now: _ts);
      final sessionId = await db.focusSessionDao
          .openSession(userId: _userId, taskIds: [planned], now: _ts);
      await db.focusSessionDao
          .setCurrentTask(sessionId: sessionId, taskId: 'offplan-1', now: _ts);
      capture.clear();

      await db.focusSessionDao.reviewAndCloseSession(
        sessionId: sessionId,
        dispositions: {planned: 'rollover', 'offplan-1': 'maybe'},
        now: _ts,
      );
      final byKey = {
        for (final op in capture.recorded) '${op.collection}/${op.entityId}': op,
      };
      expect(
        byKey['$focusSessionTasksCollection/'
                '${focusSessionTaskIdFor(sessionId, planned)}']!
            .fields['disposition'],
        'rollover',
      );
      expect(
        byKey['$focusSessionDispositionsCollection/'
                '${focusSessionDispositionIdFor(sessionId, 'offplan-1')}']!
            .fields['disposition'],
        'maybe',
      );
      expect(byKey['$todosCollection/offplan-1']!.fields['intent'], 'maybe');
      expect(byKey['$focusSessionsCollection/$sessionId']!.fields['ended_at'],
          isNotNull);
    });
  });

  group('time_log_dao and user_preferences_dao', () {
    test('openLog asserts the stint; closeLog writes ended_at', () async {
      final outcome = await seedOutcome();
      await db.timeLogDao.openLog(taskId: outcome, userId: _userId, now: _ts);
      final opened = only(timeLogsCollection);
      expect(opened.fields.keys.toSet(),
          collectionCodecs[timeLogsCollection]!.columns.keys.toSet());
      capture.clear();
      await db.timeLogDao.closeLog(taskId: outcome, now: _ts);
      expect(only(timeLogsCollection).fields, {'ended_at': _ts.toIso8601String()});
    });

    test('user preferences ride the KV entity-id policy', () async {
      await db.userPreferencesDao.set(_userId, 'theme', '"dark"');
      final op = only('user_preferences');
      expect(
        op.entityId,
        preferenceEntityId(userPreferencesWorkspaceId(_userId), 'theme'),
      );
      expect(op.fields['key'], 'theme');
      expect(op.fields['value'], '"dark"');
      // The local row is minted under the same id, so local state and the log
      // address one entity without waiting for the projector to realign it.
      final rows =
          await db.customSelect('SELECT id FROM user_preferences').get();
      expect(rows.single.read<String>('id'), op.entityId);
    });

    test('the update branch keeps row and op on one id', () async {
      // The invariant that makes the derived id the *only* id in circulation,
      // and so makes the "existing row holds a different id" divergence
      // unreachable rather than merely unlikely (issue #600). Both writers
      // derive: this DAO on INSERT, and `initial_upload_plan` when it authors a
      // pre-existing row. The projector's realignment — locating by
      // (user_id, key) and rewriting `id` — is what still catches a row some
      // *other* build minted at random; it is not what this store relies on.
      await db.userPreferencesDao.set(_userId, 'theme', '"dark"');
      capture.clear();
      await db.userPreferencesDao.set(_userId, 'theme', '"light"');

      final derived =
          preferenceEntityId(userPreferencesWorkspaceId(_userId), 'theme');
      final rows =
          await db.customSelect('SELECT id, value FROM user_preferences').get();
      expect(rows, hasLength(1), reason: 'UNIQUE(user_id, key) upsert');
      expect(rows.single.read<String>('id'), derived);
      expect(rows.single.read<String>('value'), '"light"');
      final ops = capture.forCollection(userPreferencesCollection);
      expect(ops, hasLength(1),
          reason: 'the update authors exactly one op, not none');
      expect(ops.single.entityId, derived,
          reason: 'the op names the entity the row is');
    });

    test('a captured value write always names its key', () async {
      // Protocol obligation, not a convenience: the key selects which merge
      // strategy arbitrates `value` (ADR-0033), and the receive path refuses a
      // value write that does not carry it. Both DAO branches are exercised —
      // the INSERT and the UPDATE — because either could drop the field.
      await db.userPreferencesDao.set(_userId, 'theme', '"dark"');
      await db.userPreferencesDao.set(_userId, 'theme', '"light"');
      final valueWrites = capture.recorded
          .where((op) =>
              op.collection == 'user_preferences' &&
              op.fields.containsKey('value'))
          .toList();
      expect(valueWrites, hasLength(2));
      for (final op in valueWrites) {
        expect(op.fields['key'], isA<String>(),
            reason: 'value write on ${op.entityId} carries no string key');
      }
    });
  });

  group('the seam itself', () {
    test('a rolled-back transaction authors nothing', () async {
      await expectLater(
        db.capturing(() => db.transaction(() async {
              db.opCapture.write(
                collection: todosCollection,
                entityId: 'never',
                fields: const {'title': 'never'},
              );
              throw StateError('rolled back');
            })),
        throwsStateError,
      );
      expect(capture.recorded, isEmpty);
    });

    // --- attribution under overlap (#562) -----------------------------------
    //
    // `capturing` opens its scope as its first *synchronous* statement, while
    // its body cannot run until drift's `transaction` has awaited `ensureOpen`.
    // So two un-awaited `capturing` calls **always** both open their scope
    // before either body runs — the production UI issues exactly that shape
    // (`clarify_card.dart` fires un-awaited top-level domain writes, so two
    // quick taps produce it). Attribution therefore cannot be "the scope begun
    // most recently"; it is the scope of the execution context that described
    // the effect.

    test('an op is emitted by the commit of the scope that described it',
        () async {
      final labelling = _CommitLabellingCapture();
      final overlapDb =
          GtdDatabase(NativeDatabase.memory(), opCapture: labelling);
      addTearDown(overlapDb.close);

      final a = overlapDb.capturing(() => overlapDb.todoDao
          .insertOutcome(id: 'overlap-a', title: 'A', userId: _userId, now: _ts));
      final b = overlapDb.capturing(() => overlapDb.todoDao
          .insertOutcome(id: 'overlap-b', title: 'B', userId: _userId, now: _ts));
      await a;
      await b;

      // The overlap precondition, asserted rather than assumed: were drift ever
      // to stop serialising transactions, this case would pass vacuously.
      expect(labelling.openedOver['S2'], ['S1'],
          reason: "B's scope opened while A's was still open — "
              'no overlap, no test');
      // Attribution is read off the commit that flushed each op, not off
      // emission order: a seam emitting the right ops under the wrong commit is
      // the defect, and an order-only assertion would pass on it.
      expect(labelling.emittedUnder, [
        '$todosCollection/overlap-a@S1',
        '$todosCollection/overlap-b@S2',
      ]);
    });

    test('a nested scope under an overlap emits at its own parent\'s commit',
        () async {
      final labelling = _CommitLabellingCapture();
      final overlapDb =
          GtdDatabase(NativeDatabase.memory(), opCapture: labelling);
      addTearDown(overlapDb.close);

      final a = overlapDb.capturing(() async {
        await overlapDb.todoDao
            .insertOutcome(id: 'nest-a', title: 'A', userId: _userId, now: _ts);
        await overlapDb.captureDao.insertCapture(
          CapturesCompanion(
            id: const Value('nest-cap'),
            title: const Value('also A'),
            userId: const Value(_userId),
            createdAt: Value(_ts),
            updatedAt: Value(_ts),
          ),
        );
      });
      final b = overlapDb.capturing(() => overlapDb.todoDao
          .insertOutcome(id: 'nest-b', title: 'B', userId: _userId, now: _ts));
      await a;
      await b;

      // Both of A's nested DAO scopes belong to A, even though B's scope was
      // open the whole time they were.
      expect(labelling.emittedUnder, [
        '$todosCollection/nest-a@S1',
        '$capturesCollection/nest-cap@S1',
        '$todosCollection/nest-b@S2',
      ]);
    });

    // The phantom direction, through the real DAOs: an op asserting a row this
    // store never kept, signed under the other scope's commit.
    test('an overlapping rollback authors nothing, and the committing scope '
        'authors only its own', () async {
      final rolledBack = db.capturing(() async {
        await db.todoDao.insertOutcome(
            id: 'phantom-a', title: 'never kept', userId: _userId, now: _ts);
        throw StateError('rolled back');
      });
      final committed = db.capturing(() => db.todoDao
          .insertOutcome(id: 'kept-b', title: 'kept', userId: _userId, now: _ts));
      await expectLater(rolledBack, throwsStateError);
      await committed;

      expect(await db.todoDao.getTodo('phantom-a'), isNull,
          reason: 'the rolled-back write kept no row');
      expect(await db.todoDao.getTodo('kept-b'), isNotNull);
      expect(capture.keys, ['$todosCollection/kept-b'],
          reason: 'a rolled-back write must never be signed under another '
              "scope's commit");
    });

    // The loss direction, and the severe one: the row commits, the *other*
    // scope rolls back, and `rollbackScope` clears its buffer — taking the
    // committed scope's op with it. A committed local row with no op, for ever.
    test('a committed scope keeps its op when an overlapping scope rolls back',
        () async {
      final committed = db.capturing(() => db.todoDao.insertOutcome(
          id: 'committed-a', title: 'kept', userId: _userId, now: _ts));
      // Attached before either is awaited: the rolled-back call can reject while
      // the committed one is still in flight, and an unobserved rejection would
      // surface as an unhandled error rather than as this assertion.
      final refused = expectLater(
        db.capturing(() async => throw StateError('rolled back')),
        throwsStateError,
      );
      await committed;
      await refused;

      expect(await db.todoDao.getTodo('committed-a'), isNotNull,
          reason: 'the row committed');
      expect(capture.keys, ['$todosCollection/committed-a'],
          reason: 'a committed write can never lose its op');
    });

    test('an overlapping rollback discards only its own scope', () async {
      // `capturing` awaits its own body, but nothing stops two un-awaited
      // callers overlapping. Under a stack of marks, A's rollback popped *B's*
      // mark: A's rolled-back write stayed in the buffer and B's commit signed
      // it. Token-bound scopes make that unrepresentable, and the ambient scope
      // each write is described in is what says whose write it was.
      final scopeA = capture.beginScope();
      final scopeB = capture.beginScope();
      await capture.runInScope(scopeA, () async {
        capture.write(
          collection: todosCollection,
          entityId: 'rolled-back',
          fields: const {'title': 'never signed'},
        );
      });
      await capture.runInScope(scopeB, () async {
        capture.write(
          collection: todosCollection,
          entityId: 'committed-before',
          fields: const {'title': 'survives'},
        );
      });
      capture.rollbackScope(scopeA);
      await capture.runInScope(scopeB, () async {
        capture.write(
          collection: todosCollection,
          entityId: 'committed-after',
          fields: const {'title': 'also survives'},
        );
      });
      await capture.commitScope(scopeB);

      expect(capture.keys, [
        '$todosCollection/committed-before',
        '$todosCollection/committed-after',
      ]);
    });

    test('a nested scope merges into its parent rather than emitting', () async {
      // Opened the way `capturing` opens one: the inner `beginScope` happens
      // inside the outer scope's zone, which is what makes it the outer's child.
      final outer = capture.beginScope();
      await capture.runInScope(outer, () async {
        capture.write(
          collection: todosCollection,
          entityId: 'o1',
          fields: const {'title': 'from the parent'},
        );
        final inner = capture.beginScope();
        await capture.runInScope(inner, () async {
          capture.write(
            collection: todosCollection,
            entityId: 'o1',
            fields: const {'notes': 'from the child'},
          );
        });
        await capture.commitScope(inner);
        expect(capture.recorded, isEmpty, reason: 'only the outermost emits');
      });

      await capture.commitScope(outer);
      expect(capture.keys, ['$todosCollection/o1']);
      expect(only(todosCollection).fields,
          {'title': 'from the parent', 'notes': 'from the child'});
    });

    test('two overlapping top-level scopes each emit their own writes',
        () async {
      // The same defect at its smallest — no drift, no DAOs, no timing. Both
      // scopes are open before either write is described, so "the scope begun
      // most recently" files A's write into B.
      final scopeA = capture.beginScope();
      final scopeB = capture.beginScope();
      await capture.runInScope(scopeA, () async {
        capture.write(
          collection: todosCollection,
          entityId: 'from-a',
          fields: const {'title': 'A'},
        );
      });
      await capture.runInScope(scopeB, () async {
        capture.write(
          collection: todosCollection,
          entityId: 'from-b',
          fields: const {'title': 'B'},
        );
      });

      await capture.commitScope(scopeA);
      expect(capture.keys, ['$todosCollection/from-a'],
          reason: "A's commit emits A's write, and only A's");
      await capture.commitScope(scopeB);
      expect(capture.keys,
          ['$todosCollection/from-a', '$todosCollection/from-b']);
    });

    test('a described effect with no live scope is refused, never dropped',
        () async {
      // Fail closed. A dropped op leaves a committed row nothing will ever
      // author — invisible and unrecoverable — so the seam throws at the call
      // site that caused it instead.
      expect(
        () => capture.write(
          collection: todosCollection,
          entityId: 'unscoped',
          fields: const {'title': 'nowhere to file this'},
        ),
        throwsStateError,
      );
      expect(
        () => capture.tombstone(
            collection: todosCollection, entityId: 'unscoped'),
        throwsStateError,
      );
      expect(capture.recorded, isEmpty);
    });

    test('a described effect in a closed scope is refused, not refiled',
        () async {
      final scope = capture.beginScope();
      await capture.commitScope(scope);
      await capture.runInScope(scope, () async {
        expect(
          () => capture.write(
            collection: todosCollection,
            entityId: 'too-late',
            fields: const {'title': 'after the commit'},
          ),
          throwsStateError,
        );
      });
      expect(capture.recorded, isEmpty);
    });

    test('uncapturedTransaction masks the enclosing scope rather than filing '
        'into it', () async {
      await db.capturing(() async {
        capture.write(
          collection: todosCollection,
          entityId: 'in-scope',
          fields: const {'title': 'filed'},
        );
        // The projector is the only production caller and describes no effects;
        // the mask is what makes "authors nothing" enforced rather than
        // incidental, so one that tried would be refused rather than absorbed by
        // the enclosing scope.
        await expectLater(
          db.uncapturedTransaction(() async {
            capture.write(
              collection: todosCollection,
              entityId: 'leaked',
              fields: const {'title': 'never'},
            );
          }),
          throwsStateError,
        );
      });
      expect(capture.keys, ['$todosCollection/in-scope']);
    });

    test('the no-op seam records nothing and throws nothing, in or out of a '
        'scope', () async {
      const noop = NoopDomainOpCapture();
      noop.write(
        collection: todosCollection,
        entityId: 'ignored',
        fields: const {'title': 'ignored'},
      );
      noop.tombstone(collection: todosCollection, entityId: 'ignored');
      final scope = noop.beginScope();
      await noop.runInScope(scope, () async {
        noop.write(
          collection: todosCollection,
          entityId: 'ignored',
          fields: const {'title': 'still ignored'},
        );
      });
      await noop.commitScope(scope);
      // Nothing to assert about but the absence of an exception: the no-op reads
      // no zone and keeps no buffer, so "authors nothing" is structural. A
      // GtdDatabase on it still writes rows.
      final plainDb = GtdDatabase(NativeDatabase.memory());
      addTearDown(plainDb.close);
      await plainDb.todoDao
          .insertOutcome(id: 'o1', title: 'Ship it', userId: _userId, now: _ts);
      expect(await plainDb.todoDao.getTodo('o1'), isNotNull);
    });

    test('several writes to one entity in one transaction coalesce to one op',
        () async {
      final id = await seedOutcome();
      // applyRouting writes `todos` for the routing and again for the Action
      // stamp, inside one transaction.
      await db.todoDao.applyRouting(
        id,
        to: RoutingKind.nextAction,
        actionText: 'Draft',
        now: _ts,
      );
      expect(capture.forCollection(todosCollection), hasLength(1));
      expect(only(todosCollection).fields['intent'], 'next');
      expect(only(todosCollection).fields.containsKey('last_clarified_at'), isTrue);
    });

    // T1 — the AC. A capturing body composing several capturing DAO writes and
    // then throwing must leave both the tables and the op log empty. Red under
    // the pre-fix seam, where each DAO's inner transaction auto-commits its rows
    // before the outer scope rolls its ops back: the rows survive, so the op log
    // asserts a write the store never kept the other half of.
    test('a rolled-back multi-DAO composition writes no row and authors no op',
        () async {
      await expectLater(
        db.capturing(() async {
          await db.captureDao.insertCapture(
            CapturesCompanion(
              id: const Value('cap-1'),
              title: const Value('Buy milk'),
              userId: const Value(_userId),
              createdAt: Value(_ts),
              updatedAt: Value(_ts),
            ),
          );
          await db.captureDao.assignTagHint('cap-1', 'tag-1', _userId);
          throw StateError('rolled back after both writes committed');
        }),
        throwsStateError,
      );
      expect(capture.recorded, isEmpty,
          reason: 'a rolled-back write must never be signed and queued');
      expect(await db.select(db.captures).get(), isEmpty,
          reason: 'the outer rollback must undo the DAO writes too');
      expect(await db.select(db.captureTags).get(), isEmpty);
    });

    // T2 — the commit direction. The same composition committing: every row is
    // durable and every entity's op is emitted exactly once, coalesced per
    // entity, in write order. Guards the reverse hazard — a committed write that
    // lost its op.
    test('a committed multi-DAO composition writes every row and one op per '
        'entity in write order', () async {
      await db.capturing(() async {
        await db.captureDao.insertCapture(
          CapturesCompanion(
            id: const Value('cap-1'),
            title: const Value('Buy milk'),
            userId: const Value(_userId),
            createdAt: Value(_ts),
            updatedAt: Value(_ts),
          ),
        );
        await db.captureDao.assignTagHint('cap-1', 'tag-1', _userId);
      });
      expect(await db.select(db.captures).get(), hasLength(1));
      expect(await db.select(db.captureTags).get(), hasLength(1));
      expect(capture.keys, [
        '$capturesCollection/cap-1',
        '$captureTagsCollection/${captureTagIdFor('cap-1', 'tag-1')}',
      ]);
    });

    // T3 — the guard. A bare `transaction` outside a capturing zone is refused
    // before any write lands; the named escape hatch runs and authors nothing.
    test('a bare transaction outside a capturing zone is refused before any '
        'write', () async {
      expect(
        () => db.transaction(() async {
          await db.into(db.captures).insert(
                CapturesCompanion(
                  id: const Value('cap-1'),
                  title: const Value('never'),
                  userId: const Value(_userId),
                  createdAt: Value(_ts),
                  updatedAt: Value(_ts),
                ),
              );
        }),
        throwsStateError,
      );
      expect(await db.select(db.captures).get(), isEmpty);
    });

    test('uncapturedTransaction runs the write and authors nothing', () async {
      await db.uncapturedTransaction(() async {
        await db.into(db.captures).insert(
              CapturesCompanion(
                id: const Value('cap-1'),
                title: const Value('projected'),
                userId: const Value(_userId),
                createdAt: Value(_ts),
                updatedAt: Value(_ts),
              ),
            );
      });
      expect(await db.select(db.captures).get(), hasLength(1));
      expect(capture.recorded, isEmpty,
          reason: 'the escape hatch is for writes that must never author ops');
    });
  });
}

/// A recording seam that labels every emitted op with the **commit that flushed
/// it**, and records which scopes were already open when each one began.
///
/// Both are needed to state attribution as a property rather than as an outcome.
/// Emission order alone cannot distinguish "each scope emitted its own op" from
/// "one scope emitted both, in the same order" — which is exactly the #562
/// defect — and without the overlap record a case could pass by never having
/// overlapped at all.
class _CommitLabellingCapture extends BufferedDomainOpCapture {
  final Map<CaptureScope, String> _labels = <CaptureScope, String>{};
  final List<CaptureScope> _live = <CaptureScope>[];

  /// Per scope label, the labels of the scopes already open when it began.
  final Map<String, List<String>> openedOver = <String, List<String>>{};

  /// `collection/entityId@label` per emitted op, in emission order.
  final List<String> emittedUnder = <String>[];

  String? _committing;

  @override
  CaptureScope beginScope() {
    final scope = super.beginScope();
    final label = 'S${_labels.length + 1}';
    _labels[scope] = label;
    openedOver[label] = [for (final open in _live) _labels[open]!];
    _live.add(scope);
    return scope;
  }

  @override
  Future<void> commitScope(CaptureScope scope) async {
    _live.remove(scope);
    _committing = _labels[scope];
    try {
      await super.commitScope(scope);
    } finally {
      _committing = null;
    }
  }

  @override
  void rollbackScope(CaptureScope scope) {
    _live.remove(scope);
    super.rollbackScope(scope);
  }

  @override
  Future<void> emit(CapturedOp op) async => emittedUnder
      .add('${op.collection}/${op.entityId}@${_committing ?? 'no commit'}');
}
