import 'package:flutter/widgets.dart' show Widget;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent;
import 'package:jeeves/screens/trash/trash_screen.dart';
import 'package:jeeves/widgets/active_filter_bar.dart';
import '../helpers/record_surface_test_helpers.dart';
import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  group('TrashScreen', () {
    late GtdDatabase db;

    setUp(() => db = openInMemoryDb());
    tearDown(() async => db.close());

    Widget buildScreen() =>
        buildRecordSurfaceApp(db, path: '/trash', screen: const TrashScreen());

    testWidgets(
        'lists exactly the trashed Outcomes — including completed-then-'
        'trashed — newest-trashed first', (tester) async {
      await insertClarifiedTodo(db, id: 'a', title: 'Trashed early');
      await db.todoDao
          .setIntent('a', Intent.trash, now: DateTime.utc(2026, 6, 1));
      await insertClarifiedTodo(db, id: 'b', title: 'Done then trashed');
      await db.todoDao.markDone('b');
      await db.todoDao
          .setIntent('b', Intent.trash, now: DateTime.utc(2026, 6, 2));
      await insertClarifiedTodo(db, id: 'c', title: 'Still active');

      await tester.pumpWidget(buildScreen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Trashed early'), findsOneWidget);
      expect(find.text('Done then trashed'), findsOneWidget,
          reason: 'completed-then-trashed surfaces in Trash (AC 1)');
      expect(find.text('Still active'), findsNothing);
      // Newest-trashed first: b (June 2) renders above a (June 1).
      expect(
        tester.getTopLeft(find.text('Done then trashed')).dy <
            tester.getTopLeft(find.text('Trashed early')).dy,
        isTrue,
        reason: 'newest-trashed Outcome must be listed first',
      );

      await disposeScreen(tester);
    });

    testWidgets('shows no context-filter bar (stream is unfiltered)',
        (tester) async {
      await insertClarifiedTodo(db, id: 'a', title: 'Trashed');
      await db.todoDao.setIntent('a', Intent.trash);

      await tester.pumpWidget(buildScreen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ActiveFilterBar), findsNothing);

      await disposeScreen(tester);
    });

    testWidgets('shows empty state when nothing is trashed', (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Trash is empty'), findsOneWidget);

      await disposeScreen(tester);
    });

    testWidgets('tapping a row navigates to /task/:id', (tester) async {
      await insertClarifiedTodo(db, id: 'a', title: 'Trashed');
      await db.todoDao.setIntent('a', Intent.trash);

      await tester.pumpWidget(buildScreen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Trashed'));
      await tester.pumpAndSettle();

      expect(find.text('Detail a'), findsOneWidget);

      await disposeScreen(tester);
    });
  });
}
