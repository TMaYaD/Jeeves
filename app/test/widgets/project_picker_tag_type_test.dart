/// The single-choice tag picker, driven by a tag type (#402).
///
/// The picker is the Outcome Project row today. It now serves any tag type,
/// so a habit's Area offers the same rows an Outcome's Project does — and
/// only the rows of its own type.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/widgets/project_picker.dart';

final _areaTag = Tag(id: 'area-1', name: 'Health', type: 'area', userId: 'local');
final _projectTag =
    Tag(id: 'proj-1', name: 'Garage', type: 'project', userId: 'local');

void main() {
  testWidgets('a picker set to area lists only area rows and assigns one',
      (tester) async {
    Tag? assigned;
    var cleared = false;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        tagsByTypeProvider.overrideWith((ref, type) => Stream.value(
              type == 'area' ? [_areaTag] : [_projectTag],
            )),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ProjectPickerWidget(
            tagType: 'area',
            currentTag: null,
            onAssign: (tag) => assigned = tag,
            onClear: () => cleared = true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The empty state reads as an Area, not as a project.
    expect(find.text('No Area'), findsOneWidget);
    expect(find.text('No project'), findsNothing);

    await tester.tap(find.text('No Area'));
    await tester.pumpAndSettle();

    expect(find.text('Select Area'), findsOneWidget);
    expect(find.text('Health'), findsOneWidget);
    // A project is not an Area, so it is not offered.
    expect(find.text('Garage'), findsNothing);

    await tester.tap(find.text('Health'));
    await tester.pumpAndSettle();
    expect(assigned?.id, 'area-1');
    expect(cleared, isFalse);
  });

  testWidgets('a picker set to area offers removing the Area it holds',
      (tester) async {
    var cleared = false;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        tagsByTypeProvider.overrideWith((ref, type) => Stream.value(
              type == 'area' ? [_areaTag] : [_projectTag],
            )),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ProjectPickerWidget(
            tagType: 'area',
            currentTag: _areaTag,
            onAssign: (_) {},
            onClear: () => cleared = true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Health'), findsOneWidget);
    await tester.tap(find.text('Health'));
    await tester.pumpAndSettle();

    expect(find.text('Remove Area'), findsOneWidget);
    await tester.tap(find.text('Remove Area'));
    await tester.pumpAndSettle();
    expect(cleared, isTrue);
  });
}
