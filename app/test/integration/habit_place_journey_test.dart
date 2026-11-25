/// The Habit's Place journey (issue #1075), over a real in-memory store.
///
/// A saved Habit takes a named Place, then a one-time pin, then none. The pin
/// belongs to that one Habit alone and is nowhere in the user's list of
/// places; the named Place is in that list, and stays there.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/screens/habits/habit_detail_pane.dart';
import 'package:jeeves/screens/place_management/place_management_screen.dart';

import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

/// Pumps bounded frames, letting the live store's real event loop answer
/// between them (docs/TESTING.md).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// What the Habit's Place row reads.
String _placeRowValue(WidgetTester tester) {
  final row = find.byKey(const Key('habit_row_place'));
  // The row's title is the label; its trailing text is the value.
  final texts = find.descendant(of: row, matching: find.byType(Text));
  return tester.widget<Text>(texts.last).data ?? '';
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late FakeLocationSource location;
  late String habitId;
  late String homeId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
    final now = DateTime.now();
    habitId = await db.habitDao.createHabit(
      userId: 'local',
      title: 'Walk the dog',
      today: habitDayKey(now),
      now: now,
      firstCommitment: defaultNewHabitCommitment,
    );
    homeId = (await db.placeDao.createNamedPlace(
      name: 'Home',
      latitudeDegrees: 52.3702,
      longitudeDegrees: 4.8952,
      radiusMeters: 150,
      userId: 'local',
    ))!;
    await db.placeDao.createNamedPlace(
      name: 'Office',
      latitudeDegrees: 52.3702,
      longitudeDegrees: 4.8952,
      radiusMeters: 150,
      userId: 'local',
    );
  });

  tearDown(() async {
    await location.dispose();
    await db.close();
  });

  testWidgets('a saved Habit takes a named Place, then a pin, then none', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/habits/$habitId',
      routes: [
        GoRoute(
          path: '/habits/:id',
          builder: (_, state) => HabitDetailScreen(
            habitId: state.pathParameters['id']!,
          ),
        ),
        GoRoute(
          path: '/manage/places',
          builder: (_, _) => const PlaceManagementScreen(),
        ),
      ],
    );
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
    ]);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    try {
      await _settle(tester);

      // The Habit carries no Place to begin with.
      expect(find.byKey(const Key('habit_row_place')), findsOneWidget);
      expect(_placeRowValue(tester), 'None');

      // A named Place.
      await tester.tap(find.byKey(const Key('habit_row_place')));
      await _settle(tester);
      await tester.tap(find.byKey(Key('place_picker_place_$homeId')));
      await _settle(tester);
      expect(_placeRowValue(tester), 'Home');

      // A one-time pin, which belongs to this Habit alone.
      await tester.tap(find.byKey(const Key('habit_row_place')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('place_picker_drop_pin')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const Key('place_pin_name')),
        'Post office on Mill St',
      );
      await tester.enterText(
        find.byKey(const Key('place_point_coordinates')),
        '52.3702, 4.8952',
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('place_pin_save')));
      await _settle(tester);
      // Dropping a pin is saving a Place: the first one saved may ask for the
      // location. The fake answers as the phone does, so the ask is certain.
      expect(find.byKey(const Key('location_permission_allow')), findsOneWidget);
      await tester.tap(find.byKey(const Key('location_permission_allow')));
      await _settle(tester);
      expect(_placeRowValue(tester), 'Post office on Mill St');

      // The named Place is untouched: it is still in the user's list of
      // places, and the pin is not in it.
      router.go('/manage/places');
      await _settle(tester);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Post office on Mill St'), findsNothing);

      // Clearing the Place takes the pin with it.
      router.go('/habits/$habitId');
      await _settle(tester);
      expect(_placeRowValue(tester), 'Post office on Mill St');
      await tester.tap(find.byKey(const Key('habit_row_place')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('place_picker_clear')));
      await _settle(tester);
      expect(_placeRowValue(tester), 'None');
      final pins = await tester.runAsync(
        () => db.customSelect("SELECT id FROM places WHERE kind = 'pin'").get(),
      );
      expect(pins, isEmpty);
    } finally {
      // The container is disposed here, inside the body: a live store watch
      // owns a cleanup timer, and the teardown hook runs too late for it
      // (docs/TESTING.md).
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => pumpEventQueue());
      container.dispose();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      router.dispose();
    }
  });
}
