/// The errand hand-off journey (issue #60), over a real in-memory store and
/// the real place page.
///
/// The user chooses Outcomes on the place page, taps Navigate and hands the
/// Places of those Outcomes to Google Maps or Waze. Jeeves plans no route:
/// the test reads the link Jeeves opened, in a recording stand-in for the OS.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/navigation_app_opener_provider.dart';
import 'package:jeeves/screens/place_page/place_page_screen.dart';
import 'package:jeeves/services/navigation_app_opener.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
import '../helpers/fake_navigation_app_opener.dart';
import '../test_helpers.dart';
import 'place_page_navigate_seed.dart';

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
  late FakeNavigationAppOpener opener;

  setUp(() {
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
    opener = FakeNavigationAppOpener();
  });

  tearDown(() async {
    await location.dispose();
    await db.close();
  });

  /// Runs [body] on the place page.
  Future<void> onPlacePage(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    final router = GoRouter(
      initialLocation: '/places',
      routes: [
        GoRoute(path: '/places', builder: (_, _) => const PlacePageScreen()),
      ],
    );
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      navigationAppOpenerProvider.overrideWithValue(opener),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await _settle(tester);
      await body();
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async => container.dispose());
    }
  }

  Future<void> select(WidgetTester tester, List<String> outcomeIds) async {
    await tester.longPress(find.text('Outcome ${outcomeIds.first}'));
    await _settle(tester);
    for (final id in outcomeIds.skip(1)) {
      await tester.tap(find.text('Outcome $id'));
      await _settle(tester);
    }
  }

  Future<void> tapNavigate(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('place_page_navigate')));
    await _settle(tester);
  }

  testWidgets('Google Maps gets every chosen stop in one route', (tester) async {
    await tester.runAsync(() async {
      final hardware = await seedPlace(db, 'Hardware store', 52.3702, 4.8952);
      final pharmacy = await seedPlace(db, 'Pharmacy', 52.3729, 4.8952);
      await seedOutcomeAt(db, 'paint', hardware);
      await seedOutcomeAt(db, 'pills', pharmacy);
      await seedOutcomeAt(db, 'plasters', pharmacy);
    });
    await onPlacePage(tester, () async {
      // Two Outcomes at the Pharmacy are one stop.
      await select(tester, ['paint', 'pills', 'plasters']);
      await tapNavigate(tester);
      expect(find.text('All 2 stops'), findsOneWidget);
      await tester.tap(find.byKey(const Key('navigate_google_maps')));
      await _settle(tester);

      expect(opener.calls, hasLength(1));
      final call = opener.calls.single;
      expect(call.app, NavigationApp.googleMaps);
      expect(call.uri.host, 'www.google.com');
      expect(call.uri.queryParameters['destination'], '52.372900,4.895200');
      expect(call.uri.queryParameters['waypoints'], '52.370200,4.895200');
      expect(call.uri.queryParameters.containsKey('origin'), isFalse);
      // The names of the Places stay in Jeeves.
      expect(call.uri.toString(), isNot(contains('Pharmacy')));
      // The choice is still there to come back to.
      expect(find.text('3 selected'), findsOneWidget);
    });
  });

  testWidgets('Waze gets the next stop, which the sheet names', (tester) async {
    await tester.runAsync(() async {
      final hardware = await seedPlace(db, 'Hardware store', 52.3702, 4.8952);
      final pharmacy = await seedPlace(db, 'Pharmacy', 52.3729, 4.8952);
      await seedOutcomeAt(db, 'paint', hardware);
      await seedOutcomeAt(db, 'pills', pharmacy);
    });
    await onPlacePage(tester, () async {
      await select(tester, ['pills', 'paint']);
      await tapNavigate(tester);
      expect(find.text('Next stop only: Hardware store'), findsOneWidget);
      await tester.tap(find.byKey(const Key('navigate_waze')));
      await _settle(tester);

      expect(opener.calls, hasLength(1));
      final call = opener.calls.single;
      expect(call.app, NavigationApp.waze);
      expect(call.uri.host, 'waze.com');
      expect(call.uri.queryParameters['ll'], '52.370200,4.895200');
      expect(call.uri.queryParameters['navigate'], 'yes');
    });
  });

  testWidgets(
      'fourteen stops are offered as routes of nearby stops, none dropped',
      (tester) async {
    await tester.runAsync(() async {
      // Eleven stops in two blobs about 800 m apart, and three stops 50 km
      // away. The blobs are one group of eleven, too many for one route.
      for (var i = 0; i < 6; i++) {
        final id = await seedPlace(db, 'A$i', 52.37 + i * 0.0001, 4.8952);
        await seedOutcomeAt(db, 'a$i', id);
      }
      for (var i = 0; i < 5; i++) {
        final id = await seedPlace(db, 'B$i', 52.3772 + i * 0.0001, 4.8952);
        await seedOutcomeAt(db, 'b$i', id);
      }
      for (var i = 0; i < 3; i++) {
        final id = await seedPlace(db, 'F$i', 52.08 + i * 0.0001, 4.3);
        await seedOutcomeAt(db, 'f$i', id);
      }
    });
    await onPlacePage(tester, () async {
      await tester.longPress(find.text('Outcome a0'));
      await _settle(tester);
      await tester.tap(find.text('Select all'));
      await _settle(tester);
      expect(find.text('14 selected'), findsOneWidget);
      await tapNavigate(tester);

      expect(find.text('14 stops in 3 routes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('navigate_google_maps')));
      await _settle(tester);
      expect(opener.calls, isEmpty, reason: 'choosing a route opens nothing');

      for (var index = 0; index < 3; index++) {
        expect(find.byKey(Key('navigate_route_$index')), findsOneWidget);
      }
      // Open each route in turn; the sheet closes after each, so open it
      // again.
      final waypointCounts = <int>[];
      final destinations = <String>[];
      for (var index = 0; index < 3; index++) {
        if (index > 0) {
          await tapNavigate(tester);
          await tester.tap(find.byKey(const Key('navigate_google_maps')));
          await _settle(tester);
        }
        await tester.tap(find.byKey(Key('navigate_route_$index')));
        await _settle(tester);
        final uri = opener.calls.last.uri;
        waypointCounts.add(
          (uri.queryParameters['waypoints'] ?? '').split('|').where((p) => p.isNotEmpty).length,
        );
        destinations.add(uri.queryParameters['destination']!);
      }
      expect(opener.calls, hasLength(3));
      // Six stops, five stops, three stops: each within the limit, and the
      // blobs are not joined to each other or to the far stops.
      expect(waypointCounts, [5, 4, 2]);
      expect(destinations, [
        '52.370500,4.895200',
        '52.377600,4.895200',
        '52.080200,4.300000',
      ]);
    });
  });

  testWidgets('an app that is not installed says so and changes nothing',
      (tester) async {
    opener.opens = false;
    await tester.runAsync(() async {
      final hardware = await seedPlace(db, 'Hardware store', 52.3702, 4.8952);
      await seedOutcomeAt(db, 'paint', hardware);
    });
    await onPlacePage(tester, () async {
      await select(tester, ['paint']);
      await tapNavigate(tester);
      await tester.tap(find.byKey(const Key('navigate_google_maps')));
      await _settle(tester);

      expect(opener.calls, hasLength(1));
      expect(find.text('Google Maps is not installed'), findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);
    });
  });
}
