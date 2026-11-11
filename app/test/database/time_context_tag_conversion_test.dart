/// Conversion of time-named context tags into TimeContexts (#238).
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/database/time_context_tag_conversion.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_op_capture.dart';

import '../sync/harness/reduced_state.dart' show RecordingDomainOpCapture;
import '../test_helpers.dart';

const _userId = 'local';

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

  Future<void> outcome(String id, {bool withAction = true}) async {
    await db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value('Outcome $id'),
          clarified: const Value(true),
          userId: const Value(_userId),
          createdAt: Value(DateTime.now()),
        ));
    if (withAction) {
      await seedCurrentAction(db,
          outcomeId: id, text: 'work on $id', userId: _userId);
    }
  }

  Future<void> tag(String id, String name) => db.into(db.tags).insert(
      TagsCompanion(
          id: Value(id),
          name: Value(name),
          type: const Value('context'),
          userId: const Value(_userId)));

  Future<void> link(String todoId, String tagId) =>
      db.into(db.todoTags).insert(TodoTagsCompanion(
          id: Value('$todoId-$tagId'),
          todoId: Value(todoId),
          tagId: Value(tagId),
          userId: const Value(_userId)));

  Future<Set<String>> links(String todoId) async => {
        for (final r in await (db.select(db.todoTags)
              ..where((t) => t.todoId.equals(todoId)))
            .get())
          r.tagId
      };

  test('"@Morning" becomes the morning window and the link is removed',
      () async {
    await outcome('o1');
    await tag('t-morning', '@Morning');
    await link('o1', 't-morning');

    expect(await convertTimeNamedContextTags(db), 1);

    final action = (await db.actionDao.getCurrentAction('o1'))!;
    expect(TimeContext.tryParse(action.timeContext),
        TimeContext.create(days: {1, 2, 3, 4, 5, 6, 7}, startMinute: 360, endMinute: 720));
    expect(await links('o1'), isEmpty);
    expect(await db.select(db.tags).get(), hasLength(1),
        reason: 'the Tag row is never deleted');
  });

  test('an Actionless Outcome keeps its link; non-time tags are untouched',
      () async {
    await outcome('bare', withAction: false);
    await outcome('o1');
    await tag('t-weekend', 'weekend');
    await tag('t-home', '@home');
    await link('bare', 't-weekend');
    await link('o1', 't-home');

    expect(await convertTimeNamedContextTags(db), 0);
    expect(await links('bare'), {'t-weekend'});
    expect(await links('o1'), {'t-home'});
    expect((await db.actionDao.getCurrentAction('o1'))!.timeContext, isNull);
  });

  test('an Action that already has a TimeContext is not overwritten',
      () async {
    await outcome('o1');
    final existing = TimeContext.create(days: {1})!;
    await db.actionDao.setTimeContext(
        (await db.actionDao.getCurrentAction('o1'))!.id, existing);
    await tag('t-evening', 'evening');
    await link('o1', 't-evening');

    expect(await convertTimeNamedContextTags(db), 0);
    expect((await db.actionDao.getCurrentAction('o1'))!.timeContext,
        existing.encode());
    expect(await links('o1'), {'t-evening'});
  });

  test('name matching: separators, case and the work-hours family', () {
    expect(normaliseContextTagName(' @Work-Hours '), 'work hours');
    expect(normaliseContextTagName('Office_hours'), 'office hours');
    expect(timeNamedContextTags.containsKey(normaliseContextTagName('@Night')),
        isFalse);
    expect(timeNamedContextTags.containsKey('scheduled'), isFalse);
  });

  test('a second run converts nothing', () async {
    await outcome('o1');
    await tag('t-weekday', 'weekdays');
    await link('o1', 't-weekday');
    expect(await convertTimeNamedContextTags(db), 1);
    expect(await convertTimeNamedContextTags(db), 0);
  });

  test('authors exactly the Action field write and the link tombstone',
      () async {
    await outcome('o1');
    await tag('t-weekend', 'weekend');
    await link('o1', 't-weekend');
    capture.clear();

    await convertTimeNamedContextTags(db);

    final actionOps = capture.forCollection(actionsCollection);
    expect(actionOps, hasLength(1));
    expect(actionOps.single.fields.keys,
        containsAll(['time_context', 'updated_at']));
    final linkOps = capture.forCollection(todoTagsCollection);
    expect(linkOps, hasLength(1));
    expect(linkOps.single.tombstone, isTrue);
    expect(capture.forCollection(tagsCollection), isEmpty);
    expect(capture.forCollection(todosCollection), isEmpty);
  });
}
