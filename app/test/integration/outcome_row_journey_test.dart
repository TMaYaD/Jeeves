import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/screens/common/gtd_list_screen.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/widgets/meta_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../test_helpers.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(configureSqliteForTests);
  late GtdDatabase db;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    await db
        .into(db.todos)
        .insert(
          TodosCompanion(
            id: const Value('report'),
            title: const Value('Write the report'),
            userId: const Value('local'),
            clarified: const Value(true),
            intent: const Value('next'),
            energyLevel: const Value('high'),
            timeEstimate: const Value(125),
            dueDate: Value(DateTime(2030, 3, 15)),
            createdAt: Value(DateTime.now()),
          ),
        );
  });
  tearDown(() async => db.close());

  testWidgets(
    'Next shows stored attributes and the whole row opens the Outcome',
    (tester) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => GtdListScreen(provider: nextProvider),
          ),
          GoRoute(
            path: '/task/:id',
            builder: (_, state) =>
                TaskDetailScreen(todoId: state.pathParameters['id']!),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWithValue(db)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      try {
        await _settle(tester);
        expect(find.text('Write the report'), findsOneWidget);
        expect(find.byType(OutcomeMetaLine), findsOneWidget);
        expect(find.text('High'), findsOneWidget);
        expect(find.text('2h 5m'), findsOneWidget);
        expect(find.text('Mar 15, 2030'), findsOneWidget);
        await tester.tap(find.text('2h 5m'));
        await _settle(tester);
        expect(find.byType(TaskDetailScreen), findsOneWidget);
        expect(
          tester.widget<TaskDetailScreen>(find.byType(TaskDetailScreen)).todoId,
          'report',
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
        router.dispose();
      }
    },
  );
}
