/// The label editor sheet (#402).
///
/// One sheet, two callers: the Outcome surfaces edit their labels through it,
/// and a habit's Labels use it too. It reads the applied labels live, so a
/// label applied inside the sheet is on show at once, and it reports every
/// change through callbacks, so a caller that is not an Outcome can use it.
library;

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/widgets/outcome_attribute_editors.dart';
import 'package:jeeves/widgets/tag_list.dart';

import '../test_helpers.dart';

/// The labels applied to the sheet under test.
///
/// The sheet reads this provider, and the test pushes a new list every time
/// the sheet reports a change — the way a provider re-emits after a write.
/// The sheet therefore has to read the applied labels live to stay in step.
final _appliedLabelsProvider =
    StreamProvider<List<Tag>>((ref) => _appliedLabels.stream);

late StreamController<List<Tag>> _appliedLabels;

Future<void> _insertContext(GtdDatabase db, String name) async {
  await db.tagDao.upsertTag(TagsCompanion(
    id: Value(name),
    name: Value(name),
    type: const Value('context'),
    userId: const Value('local'),
  ));
}

/// Pumps fixed steps instead of settling: the tag cloud reads a live stream.
Future<void> _pump(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    await _insertContext(db, 'Errands');
    // One subscription, so the first list waits for the sheet to read it.
    _appliedLabels = StreamController<List<Tag>>();
    addTearDown(() => _appliedLabels.close());
  });
  tearDown(() async => db.close());

  testWidgets('the sheet shows the applied labels and reports a removal',
      (tester) async {
    final removed = <String>[];
    _appliedLabels.add([
      const Tag(id: 'Errands', name: 'Errands', type: 'context', userId: 'local'),
    ]);

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLabelEditorSheet(
                context,
                watchAssignedTags: (ref) =>
                    ref.watch(_appliedLabelsProvider).asData?.value ??
                    const <Tag>[],
                onAssign: (ref, tag) => _appliedLabels.add([tag]),
                onRemove: (ref, tag) {
                  removed.add(tag.id);
                  _appliedLabels.add(const <Tag>[]);
                },
                title: 'Edit Labels',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await _pump(tester);

    await tester.tap(find.text('open'));
    await _pump(tester);

    expect(find.text('Edit Labels'), findsOneWidget);
    expect(find.text('@Errands'), findsOneWidget);

    await tester.tap(find.text('@Errands'));
    await _pump(tester);
    expect(removed, ['Errands']);
  });

  testWidgets('the sheet reports an assignment and shows the label at once',
      (tester) async {
    final assigned = <String>[];
    final removed = <String>[];

    await tester.pumpWidget(ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLabelEditorSheet(
                context,
                watchAssignedTags: (ref) =>
                    ref.watch(_appliedLabelsProvider).asData?.value ??
                    const <Tag>[],
                onAssign: (ref, tag) {
                  assigned.add(tag.id);
                  _appliedLabels.add([tag]);
                },
                onRemove: (ref, tag) {
                  removed.add(tag.id);
                  _appliedLabels.add(const <Tag>[]);
                },
                title: 'Edit Labels',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await _pump(tester);

    await tester.tap(find.text('open'));
    await _pump(tester);

    // The applied list is empty, so the dotted + is the only way in.
    expect(find.byKey(const Key('context_tag_picker_add')), findsOneWidget);
    expect(assigned, isEmpty);

    await tester.tap(find.byKey(const Key('context_tag_picker_add')));
    await _pump(tester);
    expect(find.text('@Errands'), findsOneWidget);

    await tester.tap(find.text('@Errands'));
    await _pump(tester);
    expect(assigned, ['Errands']);

    // The sheet reads the applied labels live, so the label it just applied is
    // on show in the applied row — the row ahead of the cloud.
    final appliedRow = find.byType(TagList).first;
    expect(
      find.descendant(of: appliedRow, matching: find.text('@Errands')),
      findsOneWidget,
    );

    // A second tap on the applied label removes it.
    await tester.tap(
      find.descendant(of: appliedRow, matching: find.text('@Errands')),
    );
    await _pump(tester);
    expect(removed, ['Errands']);
    expect(
      find.descendant(of: appliedRow, matching: find.text('@Errands')),
      findsNothing,
    );

    // Unmount inside the body so Drift's close timer fires before the binding
    // checks for pending timers (docs/TESTING.md, the Drift timer trap).
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 10));
  });
}
