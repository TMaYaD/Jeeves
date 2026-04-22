import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart' show Tag;
import 'package:jeeves/widgets/tag_list.dart';
import 'package:jeeves/widgets/tag_text.dart';

Tag _tag(String id, String name) =>
    Tag(id: id, name: name, type: 'context', userId: 'u1');

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  group('TagList structural invariant', () {
    testWidgets('renders each tag as TagText — no chips', (tester) async {
      final tags = [_tag('t1', 'work'), _tag('t2', 'home'), _tag('t3', 'gym')];
      await tester.pumpWidget(_wrap(TagList(tags: tags)));

      expect(find.byType(TagText), findsNWidgets(3));
      expect(find.byType(FilterChip), findsNothing);
      expect(find.byType(InputChip), findsNothing);
      expect(find.byType(ActionChip), findsNothing);
    });

    testWidgets('empty tag list renders nothing except trailing', (tester) async {
      await tester.pumpWidget(_wrap(const TagList(tags: [])));
      expect(find.byType(TagText), findsNothing);
    });

    testWidgets('trailing widget is rendered after tags', (tester) async {
      final tags = [_tag('t1', 'work')];
      await tester.pumpWidget(_wrap(TagList(
        tags: tags,
        trailing: const Text('add-button'),
      )));

      expect(find.byType(TagText), findsOneWidget);
      expect(find.text('add-button'), findsOneWidget);
    });

    testWidgets('selected tag shows checkmark prefix', (tester) async {
      final tag = _tag('t1', 'work');
      await tester.pumpWidget(_wrap(TagList(
        tags: [tag],
        selectedIds: {'t1'},
      )));

      expect(find.textContaining('✓'), findsOneWidget);
    });

    testWidgets('trailingCount suffix appears when count > 0', (tester) async {
      final tag = _tag('t1', 'work');
      await tester.pumpWidget(_wrap(TagList(
        tags: [tag],
        counts: {'t1': 5},
      )));

      expect(find.text('@work (5)'), findsOneWidget);
    });

    testWidgets('onTap callback fires with correct tag', (tester) async {
      final tag = _tag('t1', 'work');
      Tag? tapped;
      await tester.pumpWidget(_wrap(TagList(
        tags: [tag],
        onTap: (t) => tapped = t,
      )));

      await tester.tap(find.byKey(const Key('tag_chip_t1')));
      await tester.pump();

      expect(tapped?.id, equals('t1'));
    });

    testWidgets('onDismiss shows close icon and fires callback', (tester) async {
      final tag = _tag('t1', 'work');
      Tag? dismissed;
      await tester.pumpWidget(_wrap(TagList(
        tags: [tag],
        onDismiss: (t) => dismissed = t,
      )));

      expect(find.byIcon(Icons.close), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      expect(dismissed?.id, equals('t1'));
    });
  });
}
