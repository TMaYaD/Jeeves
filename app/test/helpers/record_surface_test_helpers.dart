/// Shared harness for the record-surface screen tests (Done, Trash).
///
/// Both screens are thin [GtdListScreen] wrappers over an unfiltered DAO
/// stream, so their tests share the same wiring: an in-memory database, a
/// clarified seed row, and a two-route router (the surface under test plus a
/// stub task-detail route for tap-through asserts).
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';

const _userId = 'local';

GtdDatabase openInMemoryDb() => GtdDatabase(NativeDatabase.memory());

/// Inserts a clarified, active todo — the neutral starting state the
/// record-surface tests mutate into done/trashed via DAO calls.
Future<void> insertClarifiedTodo(
  GtdDatabase db, {
  required String id,
  required String title,
}) async {
  final now = DateTime.now().toUtc();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value(title),
    clarified: const Value(true),
    userId: const Value(_userId),
    createdAt: Value(now),
    updatedAt: Value(now),
  ));
}

/// Builds a record-surface [screen] hosted at [path], with a stub
/// `/task/:id` route that renders `Detail <id>` for tap-through asserts.
Widget buildRecordSurfaceApp(
  GtdDatabase db, {
  required String path,
  required Widget screen,
}) {
  final router = GoRouter(
    initialLocation: path,
    routes: [
      GoRoute(
        path: path,
        builder: (_, _) => screen,
      ),
      GoRoute(
        path: '/task/:id',
        builder: (context, state) => Scaffold(
          body: Text('Detail ${state.pathParameters['id']}'),
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db)],
    child: MaterialApp.router(routerConfig: router),
  );
}

/// Unmounts the screen so the streaming providers dispose — and their drift
/// stream-close timers fire — before the test framework's end-of-test
/// pending-timer invariant check runs.
Future<void> disposeScreen(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}
