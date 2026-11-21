import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/services/clarification_service.dart'
    show CaptureNotFoundError;
import 'package:jeeves/services/habit_from_capture.dart';
import '../test_helpers.dart';

const _userId = 'test-user';
const _today = '2026-11-21';
final _now = DateTime.utc(2026, 11, 21, 9);

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = GtdDatabase(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  Future<void> tag(String id, String name, String type) =>
      db.into(db.tags).insert(TagsCompanion(
            id: Value(id),
            name: Value(name),
            type: Value(type),
            userId: const Value(_userId),
          ));

  Future<void> capture({required List<String> hintTagIds}) async {
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('c1'),
      title: const Value('Meditate'),
      userId: const Value(_userId),
      createdAt: Value(_now),
      updatedAt: Value(_now),
    ));
    for (final id in hintTagIds) {
      await db.captureDao.assignTagHint('c1', id, _userId);
    }
  }

  Future<String> make({String title = ' Meditate ', String? notes}) =>
      makeHabitFromCapture(db,
          captureId: 'c1',
          title: title,
          notes: notes,
          userId: _userId,
          today: _today,
          now: _now);

  test('creates the default Habit, carries Area and Labels, clears the Inbox',
      () async {
    await tag('ctx', 'Home', 'context');
    await tag('lbl', 'Calm', 'label');
    await tag('area', 'Health', 'area');
    await tag('proj', 'Move', 'project');
    await tag('pers', 'Sam', 'person');
    await capture(hintTagIds: ['ctx', 'lbl', 'area', 'proj', 'pers']);

    final habitId = await make(notes: ' a few minutes ');

    final habit = (await db.habitDao.habitById(habitId))!;
    expect(habit.title, 'Meditate');
    expect(habit.notes, 'a few minutes');
    final commitments = await db.habitDao.commitmentsFor(habitId);
    expect(commitments, hasLength(1));
    expect(commitments.single.repeatKind,
        defaultNewHabitCommitment.repeatKind);
    expect(commitments.single.isMeasurable, isFalse);
    final tags = await db.habitDao.tagsFor(habitId);
    expect(tags.map((t) => t.id).toSet(), {'ctx', 'lbl', 'area'});
    expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
    expect(await db.select(db.todos).get(), isEmpty);
    // The hints stay on the Capture as its record.
    expect(await db.captureDao.tagHintsForCapture('c1'), hasLength(5));
  });

  test('blank notes are not written', () async {
    await capture(hintTagIds: []);
    final habitId = await make(notes: '   ');
    expect((await db.habitDao.habitById(habitId))!.notes, isNull);
  });

  test('a Capture with two Area hints gives the Habit the first by name',
      () async {
    await tag('a2', 'Zen', 'area');
    await tag('a1', 'Body', 'area');
    await capture(hintTagIds: ['a2', 'a1']);
    final habitId = await make();
    expect((await db.habitDao.tagsFor(habitId)).map((t) => t.id), ['a1']);
  });

  test('an already clarified Capture throws and writes nothing', () async {
    await capture(hintTagIds: []);
    await db.captureDao.stampClarified('c1', at: _now);
    await expectLater(make(), throwsA(isA<CaptureNotFoundError>()));
    expect(await db.select(db.habits).get(), isEmpty);
  });

  test('a missing Capture throws and writes nothing', () async {
    await expectLater(make(), throwsA(isA<CaptureNotFoundError>()));
    expect(await db.select(db.habits).get(), isEmpty);
  });

  test('a failure leaves the Capture in the Inbox and no Habit', () async {
    await capture(hintTagIds: []);
    await expectLater(make(title: '   '), throwsArgumentError);
    expect(await db.select(db.habits).get(), isEmpty);
    expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNull);
  });
}
