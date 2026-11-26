/// The time chip shows a place's hours (issue #1074, step 5).
///
/// When an Action's place carries hours and no own time, the chip shows
/// the place's hours and name. Setting an own window replaces the place hours.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';

import '../test_helpers.dart';

const _userId = 'local';
final _ts = DateTime.utc(2026, 11, 24, 9);

final _storeHours = <int, DayHours>{
  for (var day = 1; day <= 5; day++)
    day: (startMinute: 11 * 60, endMinute: 20 * 60),
};

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWith((ref) => () => DateTime(2026, 11, 11, 10)),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
  });

  tearDown(() async => db.close());

  Future<String> _seedOutcome(String id) async {
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value('Outcome $id'),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db, outcomeId: id, text: 'work on $id', userId: _userId);
    return (await db.actionDao.getCurrentAction(id))!.id;
  }

  Future<String> _createPlace(String name) async {
    final id = await db.placeDao.createNamedPlace(
      name: name,
      latitudeDegrees: 52.37,
      longitudeDegrees: 4.89,
      radiusMeters: 150,
      userId: _userId,
      now: _ts,
    );
    expect(id, isNotNull);
    return id!;
  }

  testWidgets('the chip reads place hours and the place name', (tester) async {
    final placeId = await _createPlace('Hardware store');
    final actionId = await _seedOutcome('o1');
    await db.actionDao.setNamedPlace(actionId, placeId);
    await db.placeDao.setPlaceHours(
      placeId: placeId,
      hours: TimeWindowHours.create(_storeHours),
      now: _ts,
    );

    final router = GoRouter(
      initialLocation: '/task/o1',
      routes: [
        GoRoute(
          path: '/task/:id',
          builder: (_, state) =>
              TaskDetailScreen(todoId: state.pathParameters['id']!),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    try {
      await _settle(tester);

      expect(find.text('Mon–Fri 11:00–20:00 · from Hardware store'), findsOneWidget);
    } finally {
      addTearDown(tester.binding.window.physicalSizeTestValue = null);
    }
  });
}
