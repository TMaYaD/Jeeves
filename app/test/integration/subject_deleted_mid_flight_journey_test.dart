/// Integration journey (issue #447): a write that is pending when its Outcome
/// is deleted from local storage must not land.
///
/// Drives the real `/task/:id` route over a real [GtdDatabase] that records the
/// ops it authors. Two walks: an edit still in the field when the row goes, and
/// a value chosen from a sheet that was opened before the row went.
///
/// Neither can pass on `main`: the screen's old latch only blocked the dispose
/// flush, and sheet callbacks wrote straight through to the DAO, authoring an op
/// (and, for tags and Actions, inserting rows) for the deleted Outcome.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Intent, Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/inbox_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/sync/collection_codecs.dart' show todosCollection;
import 'package:jeeves/sync/domain_op_capture.dart'
    show RecordingDomainOpCapture;

import '../test_helpers.dart';

const _userId = 'local';

/// Unmounts the tree and lets the dispose flush's real I/O finish.
Future<void> unmountWhileFocused(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.runAsync(() => pumpEventQueue());
}

void main() {
  setUpAll(configureSqliteForTests);

  group('Subject deleted mid-flight (journey)', () {
    late RecordingDomainOpCapture capture;
    late GtdDatabase db;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      capture = RecordingDomainOpCapture();
      db = GtdDatabase(NativeDatabase.memory(), opCapture: capture);
      await db.todoDao
          .insertOutcome(id: 'o1', title: 'Buy milk', userId: _userId);
    });
    tearDown(() async => db.close());

    // Live row streams are stubbed (a Drift watch's zero-duration close timer
    // would outlive the test); every write still hits the real database.
    Future<void> openRoute(WidgetTester tester) async {
      final router = GoRouter(
        initialLocation: '/inbox',
        routes: [
          GoRoute(
            path: '/inbox',
            builder: (_, _) => const Scaffold(body: Text('Inbox')),
          ),
          GoRoute(
            path: '/task/:id',
            builder: (_, state) =>
                TaskDetailScreen(todoId: state.pathParameters['id']!),
          ),
        ],
      );
      final todo = (await tester.runAsync(() => db.todoDao.getTodo('o1')))!;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          inboxItemsProvider.overrideWith((_) => Stream.value([])),
          databaseProvider.overrideWithValue(db),
          taskDetailTodoProvider('o1').overrideWith((_) => Stream.value(todo)),
          taskTagsProvider('o1').overrideWith((_) => Stream.value([])),
          capturesForOutcomeProvider('o1')
              .overrideWith((_) => Stream.value([])),
          currentActionProvider('o1').overrideWith((_) => Stream.value(null)),
          plannedActionsProvider('o1').overrideWith((_) => Stream.value([])),
          terminatedActionsProvider('o1')
              .overrideWith((_) => Stream.value(const [])),
          projectTagsProvider.overrideWith((_) => Stream.value([])),
          contextTagsProvider.overrideWith((_) => Stream.value([])),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pump();
      router.push('/task/o1');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('an edit in the field when the Outcome is deleted is dropped',
        (tester) async {
      await openRoute(tester);
      await tester.enterText(
          find.byKey(const Key('task_detail_title')), 'Buy oat milk');
      await tester.pump();

      await tester.runAsync(() => db.todoDao.deleteOutcome('o1'));
      capture.clear();
      await unmountWhileFocused(tester);

      expect(await tester.runAsync(() => db.todoDao.getTodo('o1')), isNull);
      expect(capture.forCollection(todosCollection), isEmpty);
    });

    testWidgets('a value confirmed in a sheet opened before the delete is dropped',
        (tester) async {
      await openRoute(tester);
      await tester.tap(find.text('Energy'));
      await tester.pumpAndSettle();
      expect(find.text('Energy Level'), findsOneWidget);

      // The sheet is up; the row goes; then the user confirms.
      await tester.runAsync(() => db.todoDao.deleteOutcome('o1'));
      capture.clear();
      await tester.tap(find.text('High'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());

      expect(capture.forCollection(todosCollection), isEmpty);
      expect(await tester.runAsync(() => db.todoDao.getTodo('o1')), isNull);
    });
  });
}
