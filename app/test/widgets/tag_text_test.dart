import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart' show Tag;
import 'package:jeeves/widgets/tag_text.dart';

Tag _tag(String id, String name) =>
    Tag(id: id, name: name, type: 'context', userId: 'u1');

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

/// The widgets below the [TagText] under test, so an assertion about the
/// badge cannot be satisfied by the surrounding app chrome.
Finder _inTag(Finder matching) =>
    find.descendant(of: find.byType(TagText), matching: matching);

void main() {
  group('TagText selected state', () {
    testWidgets('a selected tag renders as a badge with no checkmark',
        (tester) async {
      await tester.pumpWidget(
          _wrap(TagText(tag: _tag('t1', 'work'), selected: true)));

      expect(find.text('@work'), findsOneWidget);
      expect(find.textContaining('✓'), findsNothing);
    });

    testWidgets('a selected tag draws a badge background', (tester) async {
      await tester.pumpWidget(
          _wrap(TagText(tag: _tag('t1', 'work'), selected: true)));

      expect(_inTag(find.byType(DecoratedBox)), findsOneWidget);
    });

    testWidgets('a selected tag announces itself as selected', (tester) async {
      await tester.pumpWidget(
          _wrap(TagText(tag: _tag('t1', 'work'), selected: true)));

      final selected = _inTag(find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.selected == true));
      expect(selected, findsOneWidget);
      expect(tester.widget<Semantics>(selected).properties.selected, isTrue);
    });

    testWidgets('an unselected tag draws no badge background', (tester) async {
      await tester.pumpWidget(_wrap(TagText(tag: _tag('t1', 'work'))));

      expect(find.text('@work'), findsOneWidget);
      expect(_inTag(find.byType(DecoratedBox)), findsNothing);
    });

    testWidgets('a selected tag keeps the count suffix', (tester) async {
      await tester.pumpWidget(_wrap(TagText(
        tag: _tag('t1', 'work'),
        selected: true,
        trailingCount: 5,
      )));

      expect(find.text('@work (5)'), findsOneWidget);
    });

    testWidgets('tapping a selected badge fires onTap', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(TagText(
        tag: _tag('t1', 'work'),
        selected: true,
        onTap: () => taps++,
      )));

      await tester.tap(find.text('@work'));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });
  });
}
