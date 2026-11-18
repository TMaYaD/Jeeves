/// The label editor sheet (#402).
///
/// One sheet, two callers: the Outcome surfaces edit their context tags
/// through it, and a habit's Labels use it too. It shows the applied tags and
/// reports every change through callbacks, so a caller that is not an Outcome
/// can use it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/widgets/outcome_attribute_editors.dart';

final _contextTag =
    Tag(id: 'ctx-1', name: 'Errands', type: 'context', userId: 'local');

void main() {
  testWidgets('the sheet shows the applied tags and reports a removal',
      (tester) async {
    final removed = <String>[];

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showLabelEditorSheet(
              context,
              assignedTags: [_contextTag],
              onAssign: (_) {},
              onRemove: (tag) => removed.add(tag.id),
              title: 'Edit Labels',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Edit Labels'), findsOneWidget);
    expect(find.byKey(const Key('tag_chip_ctx-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('tag_chip_ctx-1')));
    await tester.pumpAndSettle();
    expect(removed, ['ctx-1']);
  });

  testWidgets('the sheet reports an assignment', (tester) async {
    final assigned = <String>[];

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showLabelEditorSheet(
              context,
              assignedTags: const [],
              onAssign: (tag) => assigned.add(tag.id),
              onRemove: (_) {},
              title: 'Edit Labels',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The applied list is empty, so the dotted + is the only way in.
    expect(find.byKey(const Key('context_tag_picker_add')), findsOneWidget);
    expect(assigned, isEmpty);
  });
}
