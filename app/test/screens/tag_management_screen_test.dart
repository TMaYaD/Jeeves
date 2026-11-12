import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/screens/tag_management/tag_management_screen.dart';

import '../test_helpers.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _tag(GtdDatabase db, String id, String name, String type) =>
    db.tagDao.upsertTag(TagsCompanion(
      id: Value(id),
      name: Value(name),
      type: Value(type),
      userId: const Value('local'),
    ));

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() => db = GtdDatabase(NativeDatabase.memory()));
  tearDown(() async => db.close());

  Future<void> pump(WidgetTester tester, TagManagementKind kind) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(home: TagManagementScreen(kind: kind)),
      ),
    );
    await _settle(tester);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }

  for (final kind in TagManagementKind.values) {
    testWidgets('${kind.title}: empty state', (tester) async {
      await pump(tester, kind);
      expect(find.byKey(const Key('tag_management_empty')), findsOneWidget);
      expect(find.text(kind.emptyText), findsOneWidget);
      await dispose(tester);
    });
  }

  testWidgets('lists only entries of its own kind, with active counts',
      (tester) async {
    await _tag(db, 'p1', 'Garden', 'project');
    await _tag(db, 'w1', 'work', 'context');
    await _tag(db, 'a1', 'Alice', 'person');
    await pump(tester, TagManagementKind.projects);
    expect(find.text('Garden'), findsOneWidget);
    expect(find.text('work'), findsNothing);
    expect(find.text('Alice'), findsNothing);
    await dispose(tester);
  });

  testWidgets('Recolour is offered for tags only', (tester) async {
    await _tag(db, 'p1', 'Garden', 'project');
    await _tag(db, 'w1', 'work', 'context');

    await pump(tester, TagManagementKind.projects);
    await tester.tap(find.byKey(const Key('tag_management_row_p1')));
    await _settle(tester);
    expect(find.text('Recolour'), findsNothing);
    expect(find.text('Delete'), findsOneWidget);
    await dispose(tester);

    await pump(tester, TagManagementKind.tags);
    await tester.tap(find.byKey(const Key('tag_management_row_w1')));
    await _settle(tester);
    expect(find.text('Recolour'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('merge targets are limited to the same kind', (tester) async {
    await _tag(db, 'a1', 'Alice', 'person');
    await _tag(db, 'w1', 'work', 'context');
    await _tag(db, 'p1', 'Garden', 'project');

    await pump(tester, TagManagementKind.people);
    await tester.tap(find.byKey(const Key('tag_management_row_a1')));
    await _settle(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Merge into…'));
    await _settle(tester);
    expect(find.text('No other people to merge into.'), findsOneWidget);
    expect(find.text('work'), findsNothing);
    expect(find.text('Garden'), findsNothing);
    await dispose(tester);
  });

  testWidgets('renaming onto a taken name asks before merging', (tester) async {
    await _tag(db, 'a1', 'Alice', 'person');
    await _tag(db, 'a2', 'Alise', 'person');

    await pump(tester, TagManagementKind.people);
    await tester.tap(find.byKey(const Key('tag_management_row_a2')));
    await _settle(tester);
    await tester.tap(find.widgetWithText(ListTile, 'Rename'));
    await _settle(tester);
    await tester.enterText(find.byType(TextField), 'Alice');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await _settle(tester);
    expect(find.text('Name already in use'), findsOneWidget);

    // Declining leaves both entries in place.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await _settle(tester);
    final stillThere = await tester.runAsync(() => db.select(db.tags).get());
    expect(stillThere, hasLength(2));
    await dispose(tester);
  });
}
