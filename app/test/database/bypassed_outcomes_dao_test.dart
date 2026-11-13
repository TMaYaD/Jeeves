/// The Bypassed Outcome's storage rules (#107): which pass-overs `openSession` and
/// the due-date write paths record, how they are captured, and what a hard
/// delete takes with it.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/focus_session_dao.dart'
    show focusSessionPlanningBypassIdFor, focusSessionRescheduleIdFor;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/intent.dart' show Intent;
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';

import '../test_helpers.dart';

const _userId = 'u1';
final _ts = DateTime.utc(2030, 1, 10, 9);

void main() {
  setUpAll(configureSqliteForTests);

  late RecordingDomainOpCapture capture;
  late GtdDatabase db;

  setUp(() {
    capture = RecordingDomainOpCapture();
    db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
  });
  tearDown(() async => db.close());

  Future<void> outcome(String id,
      {DateTime? dueDate, bool withAction = true}) async {
    await db.todoDao.insertOutcome(
      id: id,
      title: 'Outcome $id',
      userId: _userId,
      dueDate: dueDate,
      now: _ts,
    );
    if (withAction) {
      await seedCurrentAction(db,
          outcomeId: id, text: 'work on $id', userId: _userId);
    }
  }

  Future<void> personBlock(String id) async {
    await db.into(db.tags).insert(TagsCompanion(
          id: Value('ptag-$id'),
          name: Value('Person $id'),
          type: const Value('person'),
          userId: const Value(_userId),
        ));
    await db.into(db.todoTags).insert(TodoTagsCompanion(
          id: Value('tt-$id'),
          todoId: Value(id),
          tagId: Value('ptag-$id'),
          userId: const Value(_userId),
        ));
  }

  Future<void> passOver(Set<String> ids) async {
    for (var i = 0; i < 3; i++) {
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: [],
        skippedTaskIds: ids,
        now: _ts.add(Duration(hours: 2 * i)),
      );
      await db.focusSessionDao.closeSession(
          sessionId: sessionId, now: _ts.add(Duration(hours: 2 * i + 1)));
    }
  }

  Future<List<FocusSessionPlanningBypass>> bypasses() =>
      db.select(db.focusSessionPlanningBypasses).get();
  Future<List<FocusSessionReschedule>> reschedules() =>
      db.select(db.focusSessionReschedules).get();

  group('openSession records the Planning pass-overs', () {
    test('a skip is recorded, a planned Outcome is not', () async {
      await outcome('skip');
      await outcome('plan');
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: ['plan'],
        skippedTaskIds: {'skip', 'plan'},
        now: _ts,
      );
      final rows = await bypasses();
      expect(rows.map((r) => (r.taskId, r.focusSessionId)), [
        ('skip', sessionId),
      ]);
    });

    test('a skipped Outcome deleted before Start Day leaves no row and no op',
        () async {
      await outcome('gone');
      await outcome('kept');
      await db.todoDao.deleteOutcome('gone');
      capture.clear();
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: [],
        skippedTaskIds: {'gone', 'kept'},
        now: _ts,
      );
      expect((await bypasses()).map((r) => r.taskId), ['kept']);
      expect(
          capture
              .forCollection(focusSessionPlanningBypassesCollection)
              .map((o) => o.entityId),
          [focusSessionPlanningBypassIdFor(sessionId, 'kept')]);
    });

    test('rows are captured under their pair-derived ids with exactly the '
        'codec columns', () async {
      await outcome('skip');
      capture.clear();
      final sessionId = await db.focusSessionDao.openSession(
        userId: _userId,
        taskIds: [],
        skippedTaskIds: {'skip'},
        now: _ts,
      );
      final op = capture
          .forCollection(focusSessionPlanningBypassesCollection)
          .single;
      expect(op.entityId, focusSessionPlanningBypassIdFor(sessionId, 'skip'));
      expect(op.fields.keys.toSet(),
          collectionCodecs[focusSessionPlanningBypassesCollection]!.columns.keys.toSet());
    });
  });

  group('a due-date edit records a reschedule only when it pushes later', () {
    Future<String> openWith(String id) => db.focusSessionDao
        .openSession(userId: _userId, taskIds: [id], now: _ts);

    test('moving an existing due date later while on the open Plan counts',
        () async {
      await outcome('o', dueDate: DateTime.utc(2030, 2, 1));
      final sessionId = await openWith('o');
      capture.clear();
      await db.todoDao.rescheduleTask('o', DateTime.utc(2030, 3, 1));
      expect((await reschedules()).single.focusSessionId, sessionId);
      final op =
          capture.forCollection(focusSessionReschedulesCollection).single;
      expect(op.entityId, focusSessionRescheduleIdFor(sessionId, 'o'));
      expect(op.fields.keys.toSet(),
          collectionCodecs[focusSessionReschedulesCollection]!.columns.keys.toSet());
    });

    test('the same applies through updateFields', () async {
      await outcome('o', dueDate: DateTime.utc(2030, 2, 1));
      await openWith('o');
      await db.todoDao.updateFields('o', dueDate: DateTime.utc(2030, 2, 9));
      expect(await reschedules(), hasLength(1));
    });

    test('repeated edits in one session collapse onto one row', () async {
      await outcome('o', dueDate: DateTime.utc(2030, 2, 1));
      await openWith('o');
      await db.todoDao.rescheduleTask('o', DateTime.utc(2030, 3, 1));
      await db.todoDao.rescheduleTask('o', DateTime.utc(2030, 4, 1));
      expect(await reschedules(), hasLength(1));
    });

    test('a first due date, a clear, or an earlier date does not count',
        () async {
      await outcome('first');
      await outcome('earlier', dueDate: DateTime.utc(2030, 2, 1));
      await db.focusSessionDao.openSession(
          userId: _userId, taskIds: ['first', 'earlier'], now: _ts);
      await db.todoDao.rescheduleTask('first', DateTime.utc(2030, 3, 1));
      await db.todoDao.rescheduleTask('earlier', DateTime.utc(2030, 1, 20));
      await db.todoDao.updateFields('earlier', clearDueDate: true);
      expect(await reschedules(), isEmpty);
    });

    test('with two open sessions, only the active winner\'s Plan counts',
        () async {
      // Sync can land two open sessions; open them past the writer's guard.
      Future<void> project(String id, DateTime startedAt, List<String> plan) async {
        await db.into(db.focusSessions).insert(FocusSessionsCompanion(
              id: Value(id),
              userId: const Value(_userId),
              startedAt: Value(startedAt.toIso8601String()),
              endedAt: const Value(null),
            ));
        for (final taskId in plan) {
          await db.into(db.focusSessionTasks).insert(FocusSessionTasksCompanion(
                focusSessionId: Value(id),
                taskId: Value(taskId),
                position: const Value(0),
                userId: const Value(_userId),
              ));
        }
      }

      await outcome('onlyOlder', dueDate: DateTime.utc(2030, 2, 1));
      await outcome('onlyNewer', dueDate: DateTime.utc(2030, 2, 1));
      await project('older', _ts, ['onlyOlder']);
      await project('newer', _ts.add(const Duration(hours: 1)), ['onlyNewer']);

      await db.todoDao.rescheduleTask('onlyOlder', DateTime.utc(2030, 3, 1));
      expect(await reschedules(), isEmpty, reason: 'loser-only membership');

      await db.todoDao.rescheduleTask('onlyNewer', DateTime.utc(2030, 3, 1));
      expect((await reschedules()).single.focusSessionId, 'newer');
    });

    test('with no session open, or off the Plan, it does not count', () async {
      await outcome('o', dueDate: DateTime.utc(2030, 2, 1));
      await db.todoDao.rescheduleTask('o', DateTime.utc(2030, 3, 1));
      expect(await reschedules(), isEmpty, reason: 'no session open');

      await outcome('other', dueDate: DateTime.utc(2030, 2, 1));
      await openWith('o');
      await db.todoDao.rescheduleTask('other', DateTime.utc(2030, 3, 1));
      expect(await reschedules(), isEmpty, reason: 'not on the Plan');
    });
  });

  group('getBypassedOutcomes', () {
    test('a pure Waiting For Outcome is excluded; a person-blocked one with a '
        'current Action is kept; membership changes live', () async {
      await outcome('waiting', withAction: false);
      await personBlock('waiting');
      await outcome('blockedWithAction');
      await personBlock('blockedWithAction');
      await outcome('plain');
      await passOver({'waiting', 'blockedWithAction', 'plain'});

      Future<Set<String>> ids() async => (await db.focusSessionDao
              .getBypassedOutcomes(3))
          .map((b) => b.outcome.id)
          .toSet();
      expect(await ids(), {'blockedWithAction', 'plain'});

      final seen = <Set<String>>[];
      final sub = db.focusSessionDao.watchBypassedOutcomes(3).listen(
          (rows) => seen.add(rows.map((b) => b.outcome.id).toSet()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await seedCurrentAction(db,
          outcomeId: 'waiting', text: 'now actionable', userId: _userId);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(seen.last, {'waiting', 'blockedWithAction', 'plain'});
      expect(seen.first, {'blockedWithAction', 'plain'});
    });

    test('Someday, Done and Trash Outcomes are never candidates', () async {
      await outcome('maybe');
      await outcome('done');
      await outcome('trash');
      for (var i = 0; i < 3; i++) {
        final id = await db.focusSessionDao.openSession(
          userId: _userId,
          taskIds: [],
          skippedTaskIds: {'maybe', 'done', 'trash'},
          now: _ts.add(Duration(hours: 2 * i)),
        );
        await db.focusSessionDao
            .closeSession(sessionId: id, now: _ts.add(Duration(hours: 2 * i + 1)));
      }
      await db.todoDao.setIntent('maybe', Intent.maybe);
      await db.todoDao.markDone('done');
      await db.todoDao.setIntent('trash', Intent.trash);
      expect(await db.focusSessionDao.getBypassedOutcomes(3), isEmpty);
    });

    test('a Bypassed decision is a floor: earlier pass-overs stop counting',
        () async {
      await outcome('o');
      for (var i = 0; i < 3; i++) {
        final id = await db.focusSessionDao.openSession(
          userId: _userId,
          taskIds: [],
          skippedTaskIds: {'o'},
          now: _ts.add(Duration(hours: 2 * i)),
        );
        await db.focusSessionDao
            .closeSession(sessionId: id, now: _ts.add(Duration(hours: 2 * i + 1)));
      }
      expect(await db.focusSessionDao.getBypassedOutcomes(3), hasLength(1));
      await db.into(db.outcomeBypassDecisions).insert(
            OutcomeBypassDecisionsCompanion.insert(
              taskId: 'o',
              decision: 'maybe',
              decidedAt: _ts.add(const Duration(days: 1)),
              userId: _userId,
            ),
          );
      expect(await db.focusSessionDao.getBypassedOutcomes(3), isEmpty);
    });
  });

  test('deleteOutcome removes and tombstones the Bypassed rows', () async {
    await outcome('o', dueDate: DateTime.utc(2030, 2, 1));
    final sessionId = await db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: [],
      skippedTaskIds: {'o'},
      now: _ts,
    );
    await db.into(db.focusSessionReschedules).insert(
          FocusSessionReschedulesCompanion.insert(
            id: focusSessionRescheduleIdFor(sessionId, 'o'),
            focusSessionId: sessionId,
            taskId: 'o',
            recordedAt: _ts,
            userId: _userId,
          ),
        );
    await db.into(db.outcomeBypassDecisions).insert(
          OutcomeBypassDecisionsCompanion.insert(
            taskId: 'o',
            decision: 'maybe',
            decidedAt: _ts,
            userId: _userId,
          ),
        );
    capture.clear();

    await db.todoDao.deleteOutcome('o');

    expect(await bypasses(), isEmpty);
    expect(await reschedules(), isEmpty);
    expect(await db.select(db.outcomeBypassDecisions).get(), isEmpty);
    for (final collection in [
      focusSessionPlanningBypassesCollection,
      focusSessionReschedulesCollection,
      outcomeBypassDecisionsCollection,
    ]) {
      expect(capture.forCollection(collection).single.tombstone, isTrue,
          reason: collection);
    }
  });
}
