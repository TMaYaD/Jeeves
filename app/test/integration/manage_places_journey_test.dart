/// The Places journey (issue #55), over a real in-memory store.
///
/// Settings → Manage → Places: a Place is made, edited and deleted; its area
/// runs from 50 m to 2 km; and the first saved Place is the first time Jeeves
/// asks for the location — and the only time.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/screens/place_management/place_management_screen.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/app_title_bar_test_helpers.dart';
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
  });

  tearDown(() async {
    await location.dispose();
    await db.close();
  });

  /// The real route: Settings → Manage → Places.
  Future<void> openManagePlaces(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
        GoRoute(
          path: '/manage/places',
          builder: (_, _) => const PlaceManagementScreen(),
        ),
      ],
    );
    final container = ProviderContainer(overrides: [
      nudgeBoundaryTickProvider.overrideWithValue(0),
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider
          .overrideWithValue(StubNotificationService()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await _settle(tester);
    await tester.scrollUntilVisible(
        find.byKey(const Key('manage_places_tile')), 200);
    await tester.ensureVisible(find.byKey(const Key('manage_places_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage_places_tile')));
    await _settle(tester);
  }

  /// Opens the editor for a new Place. The action sits in the title bar on a
  /// wide surface and in its ⋮ menu on a narrow one.
  Future<void> tapAddPlace(WidgetTester tester) async {
    final add =
        await findBarAction(tester, const Key('place_management_add'));
    await tester.tap(add);
  }

  /// Fills the editor with a name and a point, and saves.
  Future<void> savePlace(
    WidgetTester tester, {
    required String name,
    required String coordinates,
  }) async {
    await tester.enterText(
        find.byKey(const Key('place_editor_name')), name);
    await tester.enterText(
        find.byKey(const Key('place_point_coordinates')), coordinates);
    await tester.tap(find.byKey(const Key('place_point_apply_coordinates')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('place_editor_save')));
    await _settle(tester);
  }

  testWidgets('opening the editor asks for nothing; the first saved Place '
      'asks once, and the second does not', (tester) async {
    await openManagePlaces(tester);
    expect(find.byType(PlaceManagementScreen), findsOneWidget);

    // The editor opens without asking for the location.
    await tapAddPlace(tester);
    await _settle(tester);
    expect(find.byKey(const Key('place_editor_name')), findsOneWidget);
    expect(location.permissionRequests, 0);
    expect(location.calls, isNot(contains('requestWhileUsing')));

    // The first save is where Jeeves may ask.
    await savePlace(tester, name: 'Home', coordinates: '52.3702, 4.8952');
    expect(find.byKey(const Key('location_permission_allow')), findsOneWidget);
    await tester.tap(find.byKey(const Key('location_permission_allow')));
    await _settle(tester);
    expect(location.permissionRequests, 1);

    // The Place is saved with the default area.
    final places = await db.placeDao.watchNamedPlaces().first;
    expect(places.single.name, 'Home');
    expect(places.single.radiusMeters, 150);

    // A second Place asks nothing more.
    await tapAddPlace(tester);
    await _settle(tester);
    await savePlace(tester, name: 'Office', coordinates: '52.0800, 4.3000');
    expect(location.permissionRequests, 1);
    expect(find.byKey(const Key('location_permission_allow')), findsNothing);
  });

  testWidgets('the area runs from 50 m to 2 km', (tester) async {
    await openManagePlaces(tester);
    await tapAddPlace(tester);
    await _settle(tester);
    await tester.enterText(
        find.byKey(const Key('place_editor_name')), 'Home');
    await tester.enterText(
        find.byKey(const Key('place_point_coordinates')), '52.3702, 4.8952');
    await tester.tap(find.byKey(const Key('place_point_apply_coordinates')));
    await _settle(tester);

    // The slider ends at 50 m and at 2 km, and nowhere outside that.
    final slider = find.byKey(const Key('place_area_slider'));
    await tester.drag(slider, const Offset(-1000, 0));
    await _settle(tester);
    expect(find.text('50 m'), findsOneWidget);
    await tester.drag(slider, const Offset(1000, 0));
    await _settle(tester);
    expect(find.text('2000 m'), findsOneWidget);
  });

  testWidgets('a Place is renamed, and deleting it detaches the Action that '
      'used it', (tester) async {
    // An Outcome whose current Action is at "Home".
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
    final actionId = (await db.actionDao.getCurrentAction('o1'))!.id;
    final placeId = await db.placeDao.createNamedPlace(
      name: 'Home',
      latitudeDegrees: 52.3702,
      longitudeDegrees: 4.8952,
      radiusMeters: 150,
      userId: 'local',
    );
    await db.actionDao.setNamedPlace(actionId, placeId);

    await openManagePlaces(tester);
    expect(find.text('Home'), findsOneWidget);
    // The row says how many live Actions use the Place.
    expect(
      find.descendant(
        of: find.byKey(Key('place_management_row_$placeId')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );

    // Rename it.
    await tester.tap(find.byKey(Key('place_management_row_$placeId')));
    await _settle(tester);
    await tester.enterText(
        find.byKey(const Key('place_editor_name')), 'The house');
    await tester.tap(find.byKey(const Key('place_editor_save')));
    await _settle(tester);
    expect(find.text('The house'), findsOneWidget);

    // Delete it: the confirm names the Action that loses it.
    await tester.tap(find.byKey(Key('place_management_row_$placeId')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('place_editor_delete')));
    await _settle(tester);
    expect(find.textContaining('1 Action will lose it'), findsOneWidget);
    await tester.tap(find.byKey(const Key('place_editor_delete_confirm')));
    await _settle(tester);

    // The Action has no Place any more.
    expect(
      (await db.actionDao.placeAndTimeWindowFor(actionId)).place,
      isNull,
    );
  });
}
