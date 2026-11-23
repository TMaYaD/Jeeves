import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/sync/domain_op_capture.dart';

import '../test_helpers.dart';

/// `TagDao.retypeRetiredLabelTags`: the retired `'label'` Tag type is folded
/// into the one value Labels have, `'context'`, with nothing else touched.
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

  Future<void> tag(String id, String name, String type, {String? color}) =>
      db.tagDao.upsertTag(TagsCompanion(
        id: Value(id),
        name: Value(name),
        type: Value(type),
        color: Value(color),
        userId: const Value('u1'),
      ));

  test('retypes only \'label\' rows and keeps id, name, colour and user', () async {
    await tag('l1', 'Errands', 'label', color: '#112233');
    await tag('c1', 'Home', 'context');
    await tag('a1', 'Work', 'area');
    await tag('p1', 'Alice', 'person');

    expect(await db.tagDao.retypeRetiredLabelTags(), 1);

    final rows = {for (final t in await db.select(db.tags).get()) t.id: t};
    expect(rows['l1']!.type, 'context');
    expect(rows['l1']!.name, 'Errands');
    expect(rows['l1']!.color, '#112233');
    expect(rows['l1']!.userId, 'u1');
    expect(rows['c1']!.type, 'context');
    expect(rows['a1']!.type, 'area');
    expect(rows['p1']!.type, 'person');
  });

  test('a second run retypes nothing and authors no op', () async {
    await tag('l1', 'Errands', 'label');
    await db.tagDao.retypeRetiredLabelTags();

    capture.clear();
    expect(await db.tagDao.retypeRetiredLabelTags(), 0);
    expect(capture.recorded, isEmpty);
  });

  test('keeps the links: the tag id does not change', () async {
    await tag('l1', 'Errands', 'label');
    await db.todoDao.insertOutcome(
        id: 'o1', title: 'Buy milk', userId: 'u1', now: DateTime.utc(2026, 7, 31));
    await db.tagDao.assignTag('o1', 'l1', 'u1');

    await db.tagDao.retypeRetiredLabelTags();

    final links = await db.select(db.todoTags).get();
    expect(links.single.tagId, 'l1');
    expect((await db.tagDao.watchByType('context').first).single.name, 'Errands');
  });
}
