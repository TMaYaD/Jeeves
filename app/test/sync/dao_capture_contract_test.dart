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

    test('an overlapping rollback discards only its own scope', () async {
      // `capturing` awaits its own body, but nothing stops two un-awaited
      // callers overlapping. Under a stack of marks, A's rollback popped *B's*
      // mark: A's rolled-back write stayed in the buffer and B's commit signed
      // it. Token-bound scopes make that unrepresentable.
      final scopeA = capture.beginScope();
      capture.write(
        collection: todosCollection,
        entityId: 'rolled-back',
        fields: const {'title': 'never signed'},
      );
      final scopeB = capture.beginScope();
      capture.write(
        collection: todosCollection,
        entityId: 'committed-before',
        fields: const {'title': 'survives'},
      );
      capture.rollbackScope(scopeA);
      capture.write(
        collection: todosCollection,
        entityId: 'committed-after',
        fields: const {'title': 'also survives'},
      );
      await capture.commitScope(scopeB);

      expect(capture.keys, [
        '$todosCollection/committed-before',
        '$todosCollection/committed-after',
      ]);
    });

    test('a nested scope merges into its parent rather than emitting', () async {
      final outer = capture.beginScope();
      capture.write(
        collection: todosCollection,
        entityId: 'o1',
        fields: const {'title': 'from the parent'},
      );
      final inner = capture.beginScope();
      capture.write(
        collection: todosCollection,
        entityId: 'o1',
        fields: const {'notes': 'from the child'},
      );
      await capture.commitScope(inner);
      expect(capture.recorded, isEmpty, reason: 'only the outermost emits');

      await capture.commitScope(outer);
      expect(capture.keys, ['$todosCollection/o1']);
      expect(only(todosCollection).fields,
          {'title': 'from the parent', 'notes': 'from the child'});
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
  });
}
