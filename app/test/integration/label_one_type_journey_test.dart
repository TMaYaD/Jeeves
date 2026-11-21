import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/screens/tag_management/tag_management_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// A Label an earlier sync cutover stored under the retired `'label'` type
/// shows up on the Labels screen once the startup fold has run, with its
/// Outcome count, and a same-name Label the user made folds into one row.
void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    for (final id in ['o1', 'o2']) {
      await db.into(db.todos).insert(TodosCompanion(
            id: Value(id),
            title: Value('Outcome $id'),
            userId: const Value('local'),
            createdAt: Value(now),
            updatedAt: Value(now),
          ));
    }
    Future<void> tag(String id, String name, String type) =>
        db.tagDao.upsertTag(TagsCompanion(
            id: Value(id),
            name: Value(name),
            type: Value(type),
            userId: const Value('local')));
    await tag('errands', 'Errands', 'label');
    await tag('home-a', 'Home', 'label');
    await tag('home-b', 'Home', 'context');
    await db.tagDao.assignTag('o1', 'errands', 'local');
    await db.tagDao.assignTag('o1', 'home-a', 'local');
    await db.tagDao.assignTag('o2', 'home-b', 'local');
  });
  tearDown(() async => db.close());

  testWidgets('Settings → Labels lists a cutover Label after the startup fold',
      (tester) async {
    final container = ProviderContainer(overrides: [
      nudgeBoundaryTickProvider.overrideWithValue(0),
      databaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);

    // The startup fold, as `main.dart` runs it.
    final retyped =
        await tester.runAsync(() => container.read(labelTagTypeFoldProvider.future));
    expect(retyped, 2);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: TagManagementScreen(kind: TagManagementKind.tags),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump(const Duration(milliseconds: 150));
    }

    expect(find.text('Errands'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget,
        reason: 'the two same-name Labels fold into one row');
    final rows = await tester.runAsync(() => db.select(db.tags).get());
    expect(rows!.where((t) => t.type == 'label'), isEmpty);
    final links = await tester.runAsync(() => db.select(db.todoTags).get());
    expect(links, hasLength(3), reason: 'no link is lost');
  });
}
