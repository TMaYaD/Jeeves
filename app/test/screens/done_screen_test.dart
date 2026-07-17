import 'package:flutter/widgets.dart' show Widget;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent;
import 'package:jeeves/screens/done/done_screen.dart';
import 'package:jeeves/widgets/active_filter_bar.dart';
import '../helpers/record_surface_test_helpers.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  group('DoneScreen', () {
    late GtdDatabase db;

    setUp(() => db = openInMemoryDb());
    tearDown(() async => db.close());

    Widget buildScreen() =>
        buildRecordSurfaceApp(db, path: '/done', screen: const DoneScreen());

    testWidgets(
        'lists completed Outcomes newest-first, excluding completed-then-'
        'trashed ones', (tester) async {
      await insertClarifiedTodo(db, id: 'a', title: 'Done early');
      await db.todoDao.markDone('a', now: DateTime.utc(2026, 6, 1));
      await insertClarifiedTodo(db, id: 'b', title: 'Done late');
      await db.todoDao.markDone('b', now: DateTime.utc(2026, 6, 2));
      await insertClarifiedTodo(db, id: 'c', title: 'Done then trashed');
      await db.todoDao.markDone('c');
      await db.todoDao.setIntent('c', Intent.trash);
      await insertClarifiedTodo(db, id: 'd', title: 'Still active');

      await tester.pumpWidget(buildScreen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Done early'), findsOneWidget);
      expect(find.text('Done late'), findsOneWidget);
      expect(find.text('Done then trashed'), findsNothing,
          reason: 'a trashed-and-completed Outcome surfaces in Trash only');
      expect(find.text('Still active'), findsNothing);
      expect(
        tester.getTopLeft(find.text('Done late')).dy <
            tester.getTopLeft(find.text('Done early')).dy,
        isTrue,
        reason: 'most recently completed Outcome must be listed first',
      );

      await disposeScreen(tester);
    });

    testWidgets('shows no context-filter bar (stream is unfiltered)',
        (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ActiveFilterBar), findsNothing);
      expect(find.text('Nothing in Done'), findsOneWidget);

      await disposeScreen(tester);
    });

    testWidgets('tapping a row navigates to /task/:id', (tester) async {
      await insertClarifiedTodo(db, id: 'a', title: 'Completed thing');
      await db.todoDao.markDone('a');

      await tester.pumpWidget(buildScreen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Completed thing'));
      await tester.pumpAndSettle();

      expect(find.text('Detail a'), findsOneWidget);

      await disposeScreen(tester);
    });
  });
}
