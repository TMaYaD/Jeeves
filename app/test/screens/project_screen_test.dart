import 'package:drift/drift.dart' show Value;
import 'package:flutter/widgets.dart' show Widget;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show Intent;
import 'package:jeeves/screens/project/project_screen.dart';
import '../helpers/record_surface_test_helpers.dart';
import '../test_helpers.dart';

Future<void> _tag(GtdDatabase db, String todoId, String tagId,
    {String type = 'project'}) async {
  await db.into(db.tags).insertOnConflictUpdate(TagsCompanion(
        id: Value(tagId),
        name: Value(tagId),
        type: Value(type),
        userId: const Value('local'),
      ));
  await db.into(db.todoTags).insert(TodoTagsCompanion(
        id: Value('tt-$tagId-$todoId'),
        todoId: Value(todoId),
        tagId: Value(tagId),
        userId: const Value('local'),
      ));
}

void main() {
  setUpAll(configureSqliteForTests);

  group('ProjectScreen', () {
    late GtdDatabase db;

    setUp(() => db = openInMemoryDb());
    tearDown(() async => db.close());

    Widget buildScreen() => buildRecordSurfaceApp(db,
        path: '/projects/proj',
        screen: const ProjectScreen(projectTagId: 'proj'));

    testWidgets(
        'lists every active Outcome in the project — Next, Maybe and '
        'actionless person-blocked — and nothing else', (tester) async {
      await insertClarifiedTodo(db, id: 'n', title: 'Next outcome');
      await _tag(db, 'n', 'proj');
      await insertClarifiedTodo(db, id: 'm', title: 'Maybe outcome');
      await db.todoDao.setIntent('m', Intent.maybe);
      await _tag(db, 'm', 'proj');
      await insertClarifiedTodo(db, id: 'w', title: 'Waiting outcome');
      await _tag(db, 'w', 'proj');
      await _tag(db, 'w', 'alice', type: 'person');
      await insertClarifiedTodo(db, id: 'd', title: 'Done outcome');
      await _tag(db, 'd', 'proj');
      await db.todoDao.markDone('d');
      await insertClarifiedTodo(db, id: 't', title: 'Trashed outcome');
      await _tag(db, 't', 'proj');
      await db.todoDao.setIntent('t', Intent.trash);
      await insertClarifiedTodo(db, id: 'u', title: 'Untagged outcome');
      await insertClarifiedTodo(db, id: 'o', title: 'Other project outcome');
      await _tag(db, 'o', 'other');

      await tester.pumpWidget(buildScreen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Next outcome'), findsOneWidget);
      expect(find.text('Maybe outcome'), findsOneWidget);
      expect(find.text('Waiting outcome'), findsOneWidget);
      expect(find.text('Done outcome'), findsNothing);
      expect(find.text('Trashed outcome'), findsNothing);
      expect(find.text('Untagged outcome'), findsNothing);
      expect(find.text('Other project outcome'), findsNothing);

      await disposeScreen(tester);
    });

    testWidgets('shows the empty state for a project with no Outcomes',
        (tester) async {
      await tester.pumpWidget(buildScreen());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('No Outcomes in this project'), findsOneWidget);

      await disposeScreen(tester);
    });
  });
}
