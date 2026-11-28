/// The arrival switch journey (issue #1092), over a real in-memory store.
///
/// Settings → Manage → Places → the editor of a Place: the "Tell me when I
/// arrive" switch is the one thing that may ask the phone for "location all
/// the time", and the switch shows off unless the phone says yes.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/app_settings_provider.dart';
import 'package:jeeves/providers/arrival_notification_settings.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/screens/place_management/place_management_screen.dart';
import 'package:jeeves/screens/settings/settings_screen.dart';
import 'package:jeeves/services/location_source.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/app_title_bar_test_helpers.dart';
import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

/// Reads through a real-async turn: a Drift query awaited inside a
/// `testWidgets` body would otherwise wait on a clock that never ticks
/// (docs/TESTING.md).
Future<T> _real<T>(WidgetTester tester, Future<T> Function() body) async {
  final result = await tester.runAsync(body);
  return result as T;
}

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
  late FakeAddressGeocoder geocoder;
  late FakeAppSettingsOpener settings;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
    geocoder = FakeAddressGeocoder();
    settings = FakeAppSettingsOpener();
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
    container = ProviderContainer(overrides: [
      nudgeBoundaryTickProvider.overrideWithValue(0),
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      addressGeocoderProvider.overrideWithValue(geocoder),
      appSettingsOpenerProvider.overrideWithValue(settings),
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
    await _settle(tester);
  }

  /// Saves a Place through the editor and answers its id.
  Future<String> savePlace(
    WidgetTester tester, {
    required String name,
    required String coordinates,
  }) async {
    await tapAddPlace(tester);
    await tester.enterText(find.byKey(const Key('place_editor_name')), name);
    await tester.enterText(
        find.byKey(const Key('place_point_coordinates')), coordinates);
    await _settle(tester);
    await tester.tap(find.byKey(const Key('place_editor_save')));
    await _settle(tester);
    final places =
        await _real(tester, () => db.placeDao.watchNamedPlaces().first);
    return places.single.id;
  }

  /// Opens the editor of a Place that already exists.
  Future<void> openPlaceEditor(WidgetTester tester, String placeId) async {
    await tester.tap(find.byKey(Key('place_management_row_$placeId')));
    await _settle(tester);
  }

  /// Whether the arrival switch is on.
  bool switchValue(WidgetTester tester) => tester
      .widget<SwitchListTile>(find.byKey(const Key('place_arrival_switch')))
      .value;

  /// Moves the arrival switch.
  Future<void> tapSwitch(WidgetTester tester) async {
    final row = find.byKey(const Key('place_arrival_switch'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: row, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
  }

  /// The ids of the Places whose arrival switch is on.
  Set<String> switchedOn() =>
      container.read(arrivalPlaceIdsProvider).asData?.value ?? const <String>{};

  testWidgets('the switch asks the phone for "all the time" once, and the '
      'row then says so', (tester) async {
    // The location was already allowed on this phone, so saving a Place asks
    // nothing.
    location.permissionState = LocationPermission.whileInUse;
    await openManagePlaces(tester);
    final placeId = await savePlace(
      tester,
      name: 'Hardware store',
      coordinates: '52.3702, 4.8952',
    );

    await openPlaceEditor(tester, placeId);
    expect(find.byKey(const Key('place_arrival_switch')), findsOneWidget);
    expect(switchValue(tester), isFalse);
    // Nothing has asked for "all the time" yet.
    expect(location.allTheTimeRequests, 0);

    // The switch explains itself before the phone is asked.
    await tapSwitch(tester);
    await _settle(tester);
    expect(find.byKey(const Key('arrival_permission_continue')), findsOneWidget);
    expect(location.allTheTimeRequests, 0);

    await tester.tap(find.byKey(const Key('arrival_permission_continue')));
    await _settle(tester);

    // One ask, and the switch is on.
    expect(location.allTheTimeRequests, 1);
    expect(switchValue(tester), isTrue);
    expect(switchedOn(), contains(placeId));

    // The row says so, in words.
    await tester.ensureVisible(find.byKey(const Key('place_editor_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place_editor_save')));
    await _settle(tester);
    expect(find.text('Tells you on arrival'), findsOneWidget);
  });

  testWidgets('a phone that allows the location only while Jeeves is open '
      'leaves the switch off and says how to allow it', (tester) async {
    location.permissionState = LocationPermission.whileInUse;
    location.allTheTimeResult = LocationPermission.whileInUse;
    await openManagePlaces(tester);
    final placeId = await savePlace(
      tester,
      name: 'Hardware store',
      coordinates: '52.3702, 4.8952',
    );

    await openPlaceEditor(tester, placeId);
    await tapSwitch(tester);
    await _settle(tester);
    await tester.tap(find.byKey(const Key('arrival_permission_continue')));
    await _settle(tester);

    // The phone allowed the location only while Jeeves is open: the switch
    // stays off, and the line says where to allow it.
    expect(location.allTheTimeRequests, 1);
    expect(switchValue(tester), isFalse);
    expect(switchedOn(), isNot(contains(placeId)));
    expect(find.byKey(const Key('place_arrival_settings_line')), findsOneWidget);

    // The button opens the phone's settings, once.
    await tester.ensureVisible(
      find.byKey(const Key('place_arrival_open_settings')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place_arrival_open_settings')));
    await _settle(tester);
    expect(settings.opens, 1);
  });

  testWidgets('"Not now" asks the phone for nothing', (tester) async {
    location.permissionState = LocationPermission.whileInUse;
    await openManagePlaces(tester);
    final placeId = await savePlace(
      tester,
      name: 'Hardware store',
      coordinates: '52.3702, 4.8952',
    );

    await openPlaceEditor(tester, placeId);
    await tapSwitch(tester);
    await _settle(tester);
    await tester.tap(find.byKey(const Key('arrival_permission_not_now')));
    await _settle(tester);

    // The user said no: the phone was never asked, and the switch is off.
    expect(location.allTheTimeRequests, 0);
    expect(switchValue(tester), isFalse);
    expect(switchedOn(), isNot(contains(placeId)));
    // The line says where the permission lives, so the user can allow it
    // later without hunting for it.
    expect(find.byKey(const Key('place_arrival_settings_line')), findsOneWidget);
  });

  testWidgets('a phone that takes the permission away shows the switch off',
      (tester) async {
    location.permissionState = LocationPermission.whileInUse;
    await openManagePlaces(tester);
    final placeId = await savePlace(
      tester,
      name: 'Hardware store',
      coordinates: '52.3702, 4.8952',
    );

    // Turn the switch on.
    await openPlaceEditor(tester, placeId);
    await tapSwitch(tester);
    await _settle(tester);
    await tester.tap(find.byKey(const Key('arrival_permission_continue')));
    await _settle(tester);
    expect(switchValue(tester), isTrue);
    await tester.ensureVisible(find.byKey(const Key('place_editor_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place_editor_save')));
    await _settle(tester);

    // The user takes the permission away in the phone's settings.
    location.permissionState = LocationPermission.whileInUse;
    await openPlaceEditor(tester, placeId);

    // The switch shows off, and the line says how to allow it. The
    // preference itself is kept.
    expect(switchValue(tester), isFalse);
    expect(switchedOn(), contains(placeId));
    expect(find.byKey(const Key('place_arrival_settings_line')), findsOneWidget);
  });

  testWidgets('the row stops saying it tells you once the editor sees the '
      'permission go', (tester) async {
    location.permissionState = LocationPermission.whileInUse;
    await openManagePlaces(tester);
    final placeId = await savePlace(
      tester,
      name: 'Hardware store',
      coordinates: '52.3702, 4.8952',
    );
    await openPlaceEditor(tester, placeId);
    await tapSwitch(tester);
    await _settle(tester);
    await tester.tap(find.byKey(const Key('arrival_permission_continue')));
    await _settle(tester);
    expect(switchValue(tester), isTrue);

    // The user takes the permission away in the phone's settings and comes
    // back to the open editor.
    location.permissionState = LocationPermission.whileInUse;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester);
    expect(switchValue(tester), isFalse);

    await tester.ensureVisible(find.byKey(const Key('place_editor_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place_editor_save')));
    await _settle(tester);

    // The list read the permission afresh, not from its cache.
    expect(find.text('Tells you on arrival'), findsNothing);
  });

  testWidgets('deleting the Place forgets it', (tester) async {
    location.permissionState = LocationPermission.whileInUse;
    await openManagePlaces(tester);
    final placeId = await savePlace(
      tester,
      name: 'Hardware store',
      coordinates: '52.3702, 4.8952',
    );

    // Turn the switch on.
    await openPlaceEditor(tester, placeId);
    await tapSwitch(tester);
    await _settle(tester);
    await tester.tap(find.byKey(const Key('arrival_permission_continue')));
    await _settle(tester);
    expect(switchedOn(), contains(placeId));
    await tester.ensureVisible(find.byKey(const Key('place_editor_save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place_editor_save')));
    await _settle(tester);

    // Delete the Place.
    await openPlaceEditor(tester, placeId);
    await tester.ensureVisible(find.byKey(const Key('place_editor_delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place_editor_delete')));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('place_editor_delete_confirm')));
    await _settle(tester);

    // Its id is gone.
    expect(switchedOn(), isNot(contains(placeId)));
  });

  testWidgets('a phone with no permission prompt has no switch',
      (tester) async {
    // The web has no location prompt at all.
    location.promptSupported = false;
    location.permissionState = LocationPermission.whileInUse;
    await openManagePlaces(tester);
    final placeId = await savePlace(
      tester,
      name: 'Hardware store',
      coordinates: '52.3702, 4.8952',
    );

    await openPlaceEditor(tester, placeId);
    expect(find.byKey(const Key('place_arrival_switch')), findsNothing);
  });

  testWidgets('a Place that is not saved yet has no switch', (tester) async {
    location.permissionState = LocationPermission.whileInUse;
    await openManagePlaces(tester);
    await tapAddPlace(tester);

    // The switch belongs to a Place that exists: a new one is saved first.
    expect(find.byKey(const Key('place_arrival_switch')), findsNothing);
  });
}
