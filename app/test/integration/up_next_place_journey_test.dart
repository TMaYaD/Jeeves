/// Journey: Daily Planning's Up Next names the Place of an Outcome (#1096).
///
/// The real Daily Planning screen on its last step, over a real in-memory
/// database, with the user somewhere other than the Outcome's Place. Live Drift
/// streams run, so the test pumps bounded frames instead of `pumpAndSettle`
/// (docs/TESTING.md).
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
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/screens/planning/focus_session_planning_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/outcome_row.dart';

import '../helpers/fake_location_source.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// The user is somewhere else: far outside every Place in this test.
const _elsewhere = (latitudeDegrees: 52.0, longitudeDegrees: 4.0);

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late FakeLocationSource location;
  // Monday 23 Nov 2026, 09:00 local; the Evening Shutdown time is 18:00.
  final now = DateTime(2026, 11, 23, 9);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource()..freshPoint = _elsewhere;
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      activeSessionProvider.overrideWith((_) => Stream.value(null)),
      locationSourceProvider.overrideWithValue(location),
      currentLocationProvider.overrideWith(
        () => FixedLocationNotifier(const LocationKnown(_elsewhere)),
      ),
    ]);
  });

  tearDown(() async {
    await location.dispose();
    await db.close();
  });

  Future<void> openBuildPlan(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const FocusSessionPlanningScreen()),
      GoRoute(path: '/focus', builder: (_, _) => const SizedBox()),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    container.read(focusSessionPlanningProvider.notifier).goToStep(5);
    await _settle(tester);
  }

  Future<void> closeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async => container.dispose());
    await tester.pump();
  }

  /// Inserts a reviewed Next Outcome with a current Action; returns the id of
  /// that Action.
  Future<String> insertOutcome(WidgetTester tester, String id) async {
    return (await tester.runAsync(() async {
      final t = DateTime.now();
      await db.into(db.todos).insert(TodosCompanion(
            id: Value(id),
            title: Value('Outcome $id'),
            intent: const Value('next'),
            userId: const Value(_userId),
            createdAt: Value(t),
            updatedAt: Value(t),
          ));
      await seedCurrentAction(db,
          outcomeId: id, text: 'work on $id', userId: _userId);
      return (await db.actionDao.getCurrentAction(id))!.id;
    }))!;
  }

  Future<void> atHardwareStore(WidgetTester tester, String actionId) async {
    await tester.runAsync(() async {
      final placeId = await db.placeDao.createNamedPlace(
        name: 'Hardware store',
        latitudeDegrees: 52.3702,
        longitudeDegrees: 4.8952,
        radiusMeters: 150,
        userId: _userId,
      );
      await db.actionDao.setNamedPlace(actionId, placeId!, now: now);
    });
  }

  /// The row of the Outcome with [id], by its title.
  Finder rowOf(String id) => find.ancestor(
        of: find.text('Outcome $id'),
        matching: find.byType(OutcomeRow),
      );

  Finder inRow(String id, Finder what) =>
      find.descendant(of: rowOf(id), matching: what);

  testWidgets('an Outcome at another Place is in Up Next, named, and not on '
      'Next', (tester) async {
    final actionId = await insertOutcome(tester, 'screws');
    await atHardwareStore(tester, actionId);
    await openBuildPlan(tester);
    try {
      await pumpUntilFound(tester, find.text('Hardware store'));
      expect(find.text('UP NEXT (1)'), findsOneWidget);
      expect(inRow('screws', find.text('Hardware store')), findsOneWidget);
      expect(inRow('screws', find.byIcon(Icons.place_outlined)),
          findsOneWidget);

      // The Next list hides it while the user is away from the Place.
      final next = await tester.runAsync(() async {
        final sub = container.listen(nextProvider, (_, _) {});
        for (var i = 0; i < 20 && !sub.read().hasValue; i++) {
          await pumpEventQueue();
        }
        final value = sub.read().value;
        sub.close();
        return value;
      });
      expect(next, isNotNull);
      expect(next!.map((t) => t.id), isNot(contains('screws')));
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a Place elsewhere and a window 11:00-20:00 show both marks',
      (tester) async {
    final actionId = await insertOutcome(tester, 'screws');
    await atHardwareStore(tester, actionId);
    await tester.runAsync(() => db.actionDao.setTimeContext(
          actionId,
          TimeContext.create(
              days: {1, 2, 3, 4, 5, 6, 7},
              startMinute: 11 * 60,
              endMinute: 20 * 60),
        ));
    await openBuildPlan(tester);
    try {
      await pumpUntilFound(tester, find.text('Hardware store'));
      expect(inRow('screws', find.text('Hardware store')), findsOneWidget);
      expect(inRow('screws', find.text('from 11:00')), findsOneWidget);
      // Shape and text, not colour: each mark has its own glyph.
      expect(inRow('screws', find.byIcon(Icons.place_outlined)),
          findsOneWidget);
      expect(inRow('screws', find.byIcon(Icons.schedule)), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a one-time pin with no name is marked "Pin"', (tester) async {
    final actionId = await insertOutcome(tester, 'screws');
    await tester.runAsync(() => db.actionDao.setPin(
          actionId,
          PlaceArea.create(latitudeDegrees: 52.3702, longitudeDegrees: 4.8952)!,
          now: now,
        ));
    await openBuildPlan(tester);
    try {
      await pumpUntilFound(tester, find.text('Pin'));
      expect(inRow('screws', find.text('Pin')), findsOneWidget);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('an Outcome with no Place carries no Place mark',
      (tester) async {
    await insertOutcome(tester, 'plain');
    final placed = await insertOutcome(tester, 'screws');
    await atHardwareStore(tester, placed);
    await openBuildPlan(tester);
    try {
      await pumpUntilFound(tester, find.text('Hardware store'));
      expect(rowOf('plain'), findsOneWidget);
      expect(inRow('plain', find.byIcon(Icons.place_outlined)), findsNothing);
    } finally {
      await closeApp(tester);
    }
  });
}
