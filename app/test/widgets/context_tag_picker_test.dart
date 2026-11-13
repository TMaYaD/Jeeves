import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/widgets/context_tag_picker.dart';

import '../test_helpers.dart';

Future<Tag> _insertContext(GtdDatabase db, String name) async {
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(name),
    name: Value(name),
    type: const Value('context'),
    userId: const Value('local'),
  ));
  return (await (db.select(db.tags)..where((t) => t.id.equals(name))).get())
      .single;
}

Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late List<Tag> assigned;
  late List<Tag> removed;
  setUp(() {
    db = GtdDatabase(NativeDatabase.memory());
    assigned = [];
    removed = [];
  });
  tearDown(() async => db.close());

  Future<void> mount(WidgetTester tester, List<Tag> applied) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ContextTagPickerWidget(
              assignedTags: applied,
              onAssign: assigned.add,
              onRemove: removed.add,
            ),
          ),
        ),
      ),
    ));
    await _pump(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('collapsed shows only applied tags and a +', (tester) async {
    final home = (await tester.runAsync(() => _insertContext(db, 'home')))!;
    await tester.runAsync(() => _insertContext(db, 'work'));
    await mount(tester, [home]);

    expect(find.text('@home'), findsOneWidget);
    expect(find.text('@work'), findsNothing);
    expect(find.byKey(const Key('context_tag_picker_add')), findsOneWidget);
    expect(find.text('+ context'), findsNothing);
    expect(find.byKey(const Key('tag_cloud_find_field')), findsNothing);
    await unmount(tester);
  });

  testWidgets('tapping an applied chip removes it', (tester) async {
    final home = (await tester.runAsync(() => _insertContext(db, 'home')))!;
    await mount(tester, [home]);

    await tester.tap(find.text('@home'));
    await _pump(tester);
    expect(removed.map((t) => t.id), ['home']);
    await unmount(tester);
  });

  testWidgets('Add appears beside partial matches but not for an exact name',
      (tester) async {
    await tester.runAsync(() => _insertContext(db, 'homework'));
    await mount(tester, const []);
    await tester.tap(find.byKey(const Key('context_tag_picker_add')));
    await _pump(tester);

    final field = find.byKey(const Key('tag_cloud_find_field'));
    await tester.enterText(field, 'home');
    await _pump(tester);
    expect(find.text('@homework'), findsOneWidget);
    expect(find.text('Add "home"'), findsOneWidget);

    await tester.enterText(field, 'HomeWork');
    await _pump(tester);
    expect(find.byKey(const Key('tag_cloud_add_tag')), findsNothing);

    await tester.enterText(field, '@');
    await _pump(tester);
    expect(find.byKey(const Key('tag_cloud_add_tag')), findsNothing);
    await unmount(tester);
  });

  testWidgets('choosing Add creates the context tag and applies it',
      (tester) async {
    await mount(tester, const []);
    await tester.tap(find.byKey(const Key('context_tag_picker_add')));
    await _pump(tester);

    await tester.enterText(
        find.byKey(const Key('tag_cloud_find_field')), '@Errands');
    await _pump(tester);
    await tester.tap(find.byKey(const Key('tag_cloud_add_tag')));
    await _pump(tester);

    expect(assigned.map((t) => t.name), ['Errands']);
    expect(assigned.single.type, 'context');
    await unmount(tester);
  });
}
