import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_draft.dart';
import 'package:jeeves/models/intent.dart';
import 'package:jeeves/models/routing_kind.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/sync/collection_codecs.dart'
    show captureTagsCollection, todosCollection;
import 'package:jeeves/sync/domain_op_capture.dart'
    show RecordingDomainOpCapture;

import '../test_helpers.dart';

const _userId = 'local';

// A write only counts if it landed (#447): the guard checks the subject inside
// the write's own transaction and reports whether the write ran.
void main() {
  setUpAll(configureSqliteForTests);

  late RecordingDomainOpCapture capture;
  late GtdDatabase db;

  setUp(() {
    capture = RecordingDomainOpCapture();
    db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
  });
  tearDown(() async => db.close());

  Future<void> insertOutcome(String id) => db.todoDao
      .insertOutcome(id: id, title: 'Outcome $id', userId: _userId);

  Future<void> insertCapture(String id) =>
      db.captureDao.insertCapture(CapturesCompanion(
        id: Value(id),
        title: Value('Capture $id'),
        captureSource: const Value('manual'),
        userId: const Value(_userId),
        createdAt: Value(DateTime.now()),
        updatedAt: Value(DateTime.now()),
      ));

  group('TodoDao.writeIfOutcomePresent', () {
    test('runs the write and reports it landed when the Outcome exists',
        () async {
      await insertOutcome('o1');

      final landed = await db.todoDao.writeIfOutcomePresent(
        'o1',
        () => db.todoDao.updateFields('o1', title: 'Renamed'),
      );

      expect(landed, isTrue);
      expect((await db.todoDao.getTodo('o1'))!.title, 'Renamed');
    });

    test('skips the write, authors no op and reports false when it is gone',
        () async {
      await insertOutcome('o1');
      await db.todoDao.deleteOutcome('o1');
      capture.clear();

      final landed = await db.todoDao.writeIfOutcomePresent(
        'o1',
        () => db.todoDao.updateFields('o1', title: 'Renamed'),
      );

      expect(landed, isFalse);
      expect(await db.todoDao.getTodo('o1'), isNull);
      expect(capture.forCollection(todosCollection), isEmpty);
    });
  });

  group('TaskDetailNotifier write seam', () {
    test('every write on a deleted Outcome reports false and leaves no rows',
        () async {
      await insertOutcome('o1');
      // Real tag rows, so the assign calls would land if the guard were missing.
      final contextTagId =
          await db.tagDao.findOrCreateTag('work', 'context', _userId);
      final projectTagId =
          await db.tagDao.findOrCreateTag('Move', 'project', _userId);
      await db.todoDao.deleteOutcome('o1');
      capture.clear();
      final notifier =
          TaskDetailNotifier(db: db, userId: _userId, todoId: 'o1');

      expect(await notifier.updateTitle('x'), isFalse);
      expect(await notifier.updateNotes('x'), isFalse);
      expect(await notifier.setTimeEstimate(15), isFalse);
      expect(await notifier.clearProject(), isFalse);
      expect(await notifier.addPlannedAction(const ActionDraft(text: 'Call')), isFalse);

      // The remaining writes behind the task detail sheets and dialogs (#781).
      expect(await notifier.setIntent(Intent.maybe), isFalse);
      expect(await notifier.markDone(), isFalse);
      expect(await notifier.restoreTo(RoutingKind.nextAction), isFalse);
      expect(await notifier.clearAllPersonTags(), isFalse);
      expect(await notifier.assignContextTag(contextTagId), isFalse);
      expect(await notifier.removeContextTag(contextTagId), isFalse);
      expect(await notifier.setEnergyLevel('high'), isFalse);
      expect(await notifier.clearEnergyLevel(), isFalse);
      expect(await notifier.clearTimeEstimate(), isFalse);
      expect(await notifier.setDueDate(DateTime(2030, 1, 1)), isFalse);
      expect(await notifier.clearDueDate(), isFalse);
      expect(await notifier.assignProject(projectTagId), isFalse);
      expect(
          await notifier.editAction('a1', const ActionDraft(text: 'Call')),
          isFalse);
      expect(await notifier.supersedeAndPromote('a1'), isFalse);
      expect(await notifier.abandonCurrentAction(), isFalse);

      expect(capture.recorded, isEmpty);
      expect(await db.todoDao.getTodo('o1'), isNull);
      expect(await db.select(db.todoTags).get(), isEmpty);
      expect(await db.select(db.actions).get(), isEmpty);
    });
  });

  group('CaptureDao.writeIfCapturePresent', () {
    test('runs the tag-hint write when the Capture exists', () async {
      await insertCapture('c1');
      final tagId = await db.tagDao.findOrCreateTag('work', 'context', _userId);

      final landed = await db.captureDao.writeIfCapturePresent(
        'c1',
        () => db.captureDao.assignTagHint('c1', tagId, _userId),
      );

      expect(landed, isTrue);
      expect(await db.select(db.captureTags).get(), hasLength(1));
    });

    test('a hint write on a deleted Capture leaves no row and no op',
        () async {
      await insertCapture('c1');
      final tagId = await db.tagDao.findOrCreateTag('work', 'context', _userId);
      await (db.delete(db.captures)..where((c) => c.id.equals('c1'))).go();
      capture.clear();

      final landed = await db.captureDao.writeIfCapturePresent(
        'c1',
        () => db.captureDao.assignTagHint('c1', tagId, _userId),
      );

      expect(landed, isFalse);
      expect(await db.select(db.captureTags).get(), isEmpty);
      expect(capture.forCollection(captureTagsCollection), isEmpty);
    });
  });
}
