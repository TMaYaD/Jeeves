/// The Place chip journey (issue #55), over a real in-memory store.
///
/// The chip on an Outcome's current Action chooses a named Place, replaces it
/// with another, drops a one-time pin, and clears the Place altogether. A pin
/// belongs to that one Action and is nowhere in the user's list of places.
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
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/place_gate_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/screens/task_detail/task_detail_screen.dart';
import 'package:jeeves/widgets/outcome_peek_sheet.dart';
import 'package:jeeves/widgets/place_chip.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
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
  late FakeLocationSource location;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('o1'),
          title: const Value('Outcome o1'),
          userId: const Value('local'),
          intent: const Value('next'),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db,
        outcomeId: 'o1', text: 'work on o1', userId: 'local');
    for (final name in ['Home', 'Office']) {
      await db.placeDao.createNamedPlace(
        name: name,
        latitudeDegrees: 52.3702,
        longitudeDegrees: 4.8952,
        radiusMeters: 150,
        userId: 'local',
      );
    }
  });

  tearDown(() async {
    await location.dispose();
    await db.close();
  });

  Future<void> openDetail(WidgetTester tester) async {
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
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          locationSourceProvider.overrideWithValue(location),
          notificationServiceProvider
              .overrideWithValue(StubNotificationService()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _settle(tester);
  }

  testWidgets('the Daily Planning peek carries the same chip', (tester) async {
    final now = DateTime.now();
    final todo = Todo(
      id: 'o1',
      title: 'Outcome o1',
      doneAt: null,
      createdAt: now,
      intent: 'next',
      userId: 'local',
    );
    final action = Action(
      id: 'a1',
      outcomeId: 'o1',
      userId: 'local',
      actionText: 'work on o1',
      role: 'current',
      createdAt: now,
    );
    final homeId = (await db.placeDao.watchNamedPlaces().first).first.id;
    final place = (
      id: homeId,
      area: PlaceArea.create(
        latitudeDegrees: 52.3702,
        longitudeDegrees: 4.8952,
        radiusMeters: 150,
      )!,
      name: 'Home',
      isPin: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          locationSourceProvider.overrideWithValue(location),
          notificationServiceProvider
              .overrideWithValue(StubNotificationService()),
          taskDetailTodoProvider('o1')
              .overrideWith((_) => Stream.value(todo)),
          taskTagsProvider('o1').overrideWith((_) => Stream.value([])),
          currentActionProvider('o1').overrideWith((_) => Stream.value(action)),
          plannedActionsProvider('o1').overrideWith((_) => Stream.value([])),
          currentPlacesProvider
              .overrideWith((_) => Stream.value({'o1': place})),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => OutcomePeekSheet.show(context, todo),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('open'));
    await _settle(tester);

    // The chip reads the Place, exactly as it does on the detail.
    expect(find.byKey(const Key('place_chip')), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('the chip picks a Place, replaces it, drops a pin and clears it',
      (tester) async {
    await openDetail(tester);
    expect(find.byType(PlaceChip), findsOneWidget);
    expect(find.text('Place'), findsOneWidget);

    // Pick "Home".
    await tester.tap(find.byKey(const Key('place_chip')));
    await _settle(tester);
    await tester.tap(find.text('Home').last);
    await _settle(tester);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Place'), findsNothing);

    // Choosing another replaces it.
    await tester.tap(find.byKey(const Key('place_chip')));
    await _settle(tester);
    await tester.tap(find.text('Office').last);
    await _settle(tester);
    expect(find.text('Office'), findsOneWidget);
    expect(find.text('Home'), findsNothing);

    // Drop a pin: it belongs to this action alone.
    await tester.tap(find.byKey(const Key('place_chip')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('place_picker_drop_pin')));
    await _settle(tester);
    await tester.enterText(
        find.byKey(const Key('place_pin_name')), 'Post office on Mill St');
    await tester.enterText(
        find.byKey(const Key('place_point_coordinates')), '52.3702, 4.8952');
    await tester.tap(find.byKey(const Key('place_point_apply_coordinates')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('place_pin_save')));
    await _settle(tester);
    // Dropping a pin is saving a Place: the first one saved may ask for the
    // location.
    if (find
        .byKey(const Key('location_permission_allow'))
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.byKey(const Key('location_permission_allow')));
      await _settle(tester);
    }
    expect(find.text('Post office on Mill St'), findsOneWidget);

    // The pin is not in the user's list of places.
    final named = await db.placeDao.watchNamedPlaces().first;
    expect(named.map((p) => p.name), ['Home', 'Office']);

    // Clear it: the chip is quiet again and the pin is gone.
    await tester.tap(find.byKey(const Key('place_chip')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('place_picker_clear')));
    await _settle(tester);
    expect(find.text('Place'), findsOneWidget);
    final pins = await db.customSelect(
      'SELECT id FROM places WHERE kind = \'pin\'',
    ).get();
    expect(pins, isEmpty);
  });
}
