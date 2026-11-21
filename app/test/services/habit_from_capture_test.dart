/// Making a Habit from an Inbox capture (#999), on a real in-memory database.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/services/habit_from_capture.dart';

import '../test_helpers.dart';

const _userId = 'local';

Future<void> _insertCapture(
  GtdDatabase db,
  String id,
  String title, {
  String? notes,
  DateTime? clarifiedAt,
}) {
  final now = DateTime.now();
  return db.captureDao.insertCapture(
    CapturesCompanion(
      id: Value(id),
      title: Value(title),
      notes: Value(notes),
      captureSource: const Value('manual'),
      userId: const Value(_userId),
      createdAt: Value(now),
      updatedAt: Value(now),
      clarifiedAt: Value(clarifiedAt),
    ),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  final today = habitDayKey(DateTime.now());

  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  Future<String> make(
    String captureId, {
    String title = 'Stretch',
    String? notes,
  }) => makeHabitFromCapture(
    db,
    captureId: captureId,
    title: title,
    notes: notes,
    userId: _userId,
    today: today,
  );

  test('creates a Habit with the passed title and notes and the default '
      'commitment', () async {
    await _insertCapture(db, 'c1', 'Stretch');

    final habitId = await make('c1', title: '  Stretch daily ', notes: 'Hips');

    final habit = (await db.habitDao.habitById(habitId))!;
    expect(habit.title, 'Stretch daily');
    expect(habit.notes, 'Hips');
    final commitments = await db.select(db.habitCommitments).get();
    expect(commitments, hasLength(1));
    expect(
      commitments.single.repeatKind,
      defaultNewHabitCommitment.repeatKind.storedValue,
    );
  });

  test('blank notes are not carried', () async {
    await _insertCapture(db, 'c1', 'Stretch');
    final habitId = await make('c1', notes: '   ');
    expect((await db.habitDao.habitById(habitId))!.notes, isNull);
  });

  test(
    'carries the Area and the Labels, and not the Project or Person',
    () async {
      await _insertCapture(db, 'c1', 'Stretch');
      final area = await db.tagDao.findOrCreateTag('Health', 'area', _userId);
      final ctx = await db.tagDao.findOrCreateTag('home', 'context', _userId);
      final label = await db.tagDao.findOrCreateTag('daily', 'label', _userId);
      final project = await db.tagDao.findOrCreateTag(
        'Fit',
        'project',
        _userId,
      );
      final person = await db.tagDao.findOrCreateTag('Bob', 'person', _userId);
      for (final t in [area, ctx, label, project, person]) {
        await db.captureDao.assignTagHint('c1', t, _userId);
      }

      final habitId = await make('c1');

      final tags = await db.habitDao.tagsFor(habitId);
      expect(tags.map((t) => t.id).toSet(), {area, ctx, label});
      // The hints stay on the Capture as its record.
      expect(await db.captureDao.tagHintsForCapture('c1'), hasLength(5));
    },
  );

  test('two Area hints give the Habit the first by name', () async {
    await _insertCapture(db, 'c1', 'Stretch');
    final b = await db.tagDao.findOrCreateTag('Body', 'area', _userId);
    final a = await db.tagDao.findOrCreateTag('Absolutely', 'area', _userId);
    await db.captureDao.assignTagHint('c1', b, _userId);
    await db.captureDao.assignTagHint('c1', a, _userId);

    final habitId = await make('c1');

    expect((await db.habitDao.tagsFor(habitId)).map((t) => t.id), [a]);
  });

  test(
    'stamps the Capture clarified, leaves the Inbox, makes no Outcome',
    () async {
      await _insertCapture(db, 'c1', 'Stretch');

      await make('c1');

      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      expect(await db.captureDao.watchInbox().first, isEmpty);
      expect(await db.select(db.todos).get(), isEmpty);
    },
  );

  test('an already clarified Capture and a missing one throw and write '
      'nothing', () async {
    await _insertCapture(db, 'done', 'Old', clarifiedAt: DateTime.now());

    await expectLater(make('done'), throwsA(isA<CaptureNotFoundError>()));
    await expectLater(make('nope'), throwsA(isA<CaptureNotFoundError>()));
    expect(await db.select(db.habits).get(), isEmpty);
  });

  test(
    'a failure rolls back: no Habit, the Capture stays in the Inbox',
    () async {
      await _insertCapture(db, 'c1', 'Stretch');

      await expectLater(
        make('c1', title: '   '),
        throwsA(isA<ArgumentError>()),
      );

      expect(await db.select(db.habits).get(), isEmpty);
      expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNull);
    },
  );
}
