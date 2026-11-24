/// The location-unknown journey (issue #55), over a real in-memory store.
///
/// With no location, an Outcome that carries a Place stays on Next and says
/// where it is, and one calm line says Jeeves does not know where the user
/// is. With a location, there is no line. With no placed Outcome, there is no
/// line either. Where the OS has refused the location, the line's button asks
/// again; where the OS will not ask again, it opens the app's settings.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/app_settings_provider.dart';
import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/screens/next/next_screen.dart';
import 'package:jeeves/services/location_source.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// Reads through a real-async turn: a Drift query awaited inside a
/// `testWidgets` body would otherwise wait on a clock that never ticks
/// (docs/TESTING.md).
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
  late FakeAppSettingsOpener settings;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
    settings = FakeAppSettingsOpener();
  });

  tearDown(() async {
    await location.dispose();
    await db.close();
  });

  /// Seeds an Outcome whose current Action is at a Place named "Home".
  Future<void> seedPlacedOutcome({String id = 'o1'}) async {
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value('Outcome $id'),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db,
        outcomeId: id, text: 'work on $id', userId: _userId);
    final placeId = await db.placeDao.createNamedPlace(
      name: 'Home',
      latitudeDegrees: 52.3702,
      longitudeDegrees: 4.8952,
      radiusMeters: 150,
      userId: _userId,
    );
    final actionId = (await db.actionDao.getCurrentAction(id))!.id;
    await db.actionDao.setNamedPlace(actionId, placeId!);
  }

  /// Seeds an Outcome with no Place at all.
  Future<void> seedPlainOutcome({String id = 'o1'}) async {
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value('Outcome $id'),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db,
        outcomeId: id, text: 'work on $id', userId: _userId);
  }

  /// The Next screen, over the real store, with the location stood in for.
  Future<ProviderContainer> pumpNext(
    WidgetTester tester, {
    required CurrentLocation current,
  }) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      appSettingsOpenerProvider.overrideWithValue(settings),
      notificationServiceProvider
          .overrideWithValue(StubNotificationService()),
      currentLocationProvider.overrideWith(() => FixedLocationNotifier(current)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: NextScreen()),
      ),
    );
    await _settle(tester);
    return container;
  }

  testWidgets('with no location the line is shown and the row names the '
      'Place', (tester) async {
    await seedPlacedOutcome();
    await pumpNext(tester, current: const LocationUnknown());

    expect(find.byKey(const Key('location_unknown_line')), findsOneWidget);
    // The row still says where the Outcome is.
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('with a location there is no line', (tester) async {
    await seedPlacedOutcome();
    await pumpNext(
      tester,
      current: const LocationKnown((
        latitudeDegrees: 52.3702,
        longitudeDegrees: 4.8952,
      )),
    );

    expect(find.byKey(const Key('location_unknown_line')), findsNothing);
  });

  testWidgets('with no placed Outcome there is no line', (tester) async {
    await seedPlainOutcome();
    await pumpNext(tester, current: const LocationUnknown());

    expect(find.byKey(const Key('location_unknown_line')), findsNothing);
  });

  testWidgets('a refused permission leaves a button that asks again',
      (tester) async {
    location.permissionState = LocationPermission.denied;
    await seedPlacedOutcome();
    await pumpNext(tester, current: const LocationUnknown());

    expect(find.byKey(const Key('location_unknown_allow')), findsOneWidget);
    await tester.tap(find.byKey(const Key('location_unknown_allow')));
    await _settle(tester);
    expect(location.permissionRequests, 1);
    // The OS may still ask, so the app's settings are not opened.
    expect(settings.opens, 0);
  });

  testWidgets('where the OS will not ask again, the app\'s settings open',
      (tester) async {
    location.permissionState = LocationPermission.denied;
    // The refusal for good is only ever seen in the result of the ask.
    location.requestResult = LocationPermission.deniedForever;
    await seedPlacedOutcome();
    await pumpNext(tester, current: const LocationUnknown());

    expect(find.byKey(const Key('location_unknown_allow')), findsOneWidget);
    await tester.tap(find.byKey(const Key('location_unknown_allow')));
    await _settle(tester);
    expect(location.permissionRequests, 1);
    expect(settings.opens, 1);
  });

  testWidgets('with the location allowed but no fix, there is no button',
      (tester) async {
    // The location is allowed; the phone simply has not found the user.
    location.permissionState = LocationPermission.whileInUse;
    await seedPlacedOutcome();
    await pumpNext(tester, current: const LocationUnknown());

    expect(find.byKey(const Key('location_unknown_line')), findsOneWidget);
    // Allowing it again would do nothing.
    expect(find.byKey(const Key('location_unknown_allow')), findsNothing);
  });

  testWidgets('the line keeps its wording between rebuilds', (tester) async {
    await seedPlacedOutcome();
    final container = await pumpNext(tester, current: const LocationUnknown());

    final before = tester
        .widget<Text>(find.byKey(const Key('location_unknown_line')))
        .data;
    // Any provider tick rebuilds the line.
    container.invalidate(locationPermissionProvider);
    await _settle(tester);
    final after = tester
        .widget<Text>(find.byKey(const Key('location_unknown_line')))
        .data;

    expect(after, before);
  });
}
