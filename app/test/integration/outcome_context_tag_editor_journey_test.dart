/// Journey: editing an Outcome's context tags from the detail screen (#880).
///
/// The real [TaskDetailScreen] over a real in-memory database. The tag section
/// shows only applied tags and a dotted `+`; the `+` opens the searchable tag
/// cloud, where a name no tag has can be created and applied in one step. Live
/// Drift watches are running, so the test pumps fixed durations rather than
/// `pumpAndSettle` (TESTING.md).
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/widgets/dotted_add_button.dart';

import '../test_helpers.dart';

Future<void> _insertOutcome(GtdDatabase db, String id, String title) =>
    db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value(title),
          intent: const Value('next'),
          userId: const Value('local'),
          createdAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ));

Future<void> _insertContext(GtdDatabase db, String name) =>
    db.tagDao.upsertTag(TagsCompanion(
      id: Value(name),
      name: Value(name),
      type: const Value('context'),
      userId: const Value('local'),
    ));

Future<void> _pumpFor(WidgetTester tester, [int steps = 4]) async {
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await _insertOutcome(db, 'o1', 'Sort the garage');
    await _insertOutcome(db, 'o2', 'Other work');
    // Fourteen busy tags: a01 and a02 are applied to o1, the rest only to o2.
    for (var i = 1; i <= 14; i++) {
      final name = 'a${i.toString().padLeft(2, '0')}';
      await _insertContext(db, name);
      await db.tagDao.assignTag(i <= 2 ? 'o1' : 'o2', name, 'local');
    }
    // A tag no Outcome carries.
    await _insertContext(db, 'zz-unused');
  });
  tearDown(() async => db.close());

  testWidgets('applied tags and a dotted +, then search, create and apply',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(home: TaskDetailScreen(todoId: 'o1')),
    ));
    await _pumpFor(tester);

    // Only the applied tags are listed, with the dotted +.
    expect(find.byKey(const Key('tag_chip_a01')), findsOneWidget);
    expect(find.byKey(const Key('tag_chip_a02')), findsOneWidget);
    expect(find.byKey(const Key('tag_chip_a03')), findsNothing);
    expect(find.byType(DottedAddButton), findsOneWidget);

    // The + opens the organised cloud: applied tags pinned, capped at 12 with
    // show-more, and a Find field.
    await tester.tap(find.byType(DottedAddButton));
    await _pumpFor(tester);
    final cloud = find.byKey(const Key('context_tag_picker_cloud'));
    Finder chipInCloud(String id) =>
        find.descendant(of: cloud, matching: find.byKey(Key('tag_chip_$id')));
    expect(find.textContaining('✓ @a01'), findsOneWidget);
    expect(chipInCloud('a03'), findsOneWidget);
    expect(chipInCloud('a12'), findsOneWidget);
    expect(chipInCloud('a13'), findsNothing);
    expect(find.byKey(const Key('tag_cloud_show_more')), findsOneWidget);
    expect(find.text('Show 3 more'), findsOneWidget);
    expect(find.byKey(const Key('tag_cloud_find_field')), findsOneWidget);

    // Search ignores case and a leading @; a tag nobody uses is findable and
    // needs no Add.
    await tester.enterText(
        find.byKey(const Key('tag_cloud_find_field')), '@ZZ-UN');
    await _pumpFor(tester);
    expect(chipInCloud('zz-unused'), findsOneWidget);
    expect(find.byKey(const Key('tag_cloud_add_tag')), findsNothing);

    // A name no tag has offers Add, which creates the context tag and applies
    // it.
    await tester.enterText(
        find.byKey(const Key('tag_cloud_find_field')), '@Errands');
    await _pumpFor(tester);
    expect(find.text('Add "Errands"'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tag_cloud_add_tag')));
    await _pumpFor(tester);

    final created = await tester.runAsync(() => (db.select(db.tags)
          ..where((t) => t.name.equals('Errands') & t.type.equals('context')))
        .get());
    expect(created, hasLength(1));
    final linked = await tester.runAsync(() => (db.select(db.todoTags)
          ..where((t) => t.todoId.equals('o1')))
        .get());
    expect(linked!.map((r) => r.tagId), contains(created!.single.id));
    expect(find.textContaining('✓ @Errands'), findsWidgets);

    // Tapping an unapplied tag applies it; tapping an applied one removes it.
    await tester.enterText(find.byKey(const Key('tag_cloud_find_field')), 'a05');
    await _pumpFor(tester);
    await tester.tap(chipInCloud('a05'));
    await _pumpFor(tester);
    var ids = (await tester.runAsync(() => (db.select(db.todoTags)
              ..where((t) => t.todoId.equals('o1')))
            .get()))!
        .map((r) => r.tagId);
    expect(ids, contains('a05'));
    await tester.tap(chipInCloud('a05'));
    await _pumpFor(tester);
    ids = (await tester.runAsync(() => (db.select(db.todoTags)
              ..where((t) => t.todoId.equals('o1')))
            .get()))!
        .map((r) => r.tagId);
    expect(ids, isNot(contains('a05')));

    // Long-press opens the colour picker.
    await tester.longPress(chipInCloud('a05'));
    await _pumpFor(tester);
    expect(find.text('Color for @a05'), findsOneWidget);

    // Unmount inside the body so Drift's stream-close timers fire here.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  });
}
