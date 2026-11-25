/// The clarify card's Place chip journey (issue #1078), over a real
/// in-memory store.
///
/// The user clarifies an Inbox Capture and says where the Action that
/// clarification creates happens. The Outcome lands at that Place: off the
/// Next list while the user is somewhere else, and on the place page under
/// the Place's name.
///
/// A pin is a Place too — one that belongs to that Action alone — and the
/// first Place saved may ask for the location.
///
/// The Capture itself is never written: it stays the raw record of what was
/// captured, title, notes and tag hints alike.
library;

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_place_and_time_window.dart';
import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/place_gate_provider.dart';
import 'package:jeeves/providers/place_page_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/router.dart';
import 'package:jeeves/services/location_source.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// The point of the Place named "Hardware store".
const GeoPoint _store = (
  latitudeDegrees: 52.3702,
  longitudeDegrees: 4.8952,
);

/// A point about 40 km away — nowhere near the store.
const GeoPoint _elsewhere = (
  latitudeDegrees: 52.0800,
  longitudeDegrees: 4.3000,
);

/// Settles the tree and lets real async work finish.
///
/// The Inbox and the clarify screen read live drift streams, so
/// `pumpAndSettle` never reaches a quiet frame — a bounded drain is what the
/// other journeys over these very screens use (docs/TESTING.md).
Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late FakeLocationSource location;
  late ProviderContainer container;
  late String storePlaceId;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    location = FakeLocationSource();
    // The user has allowed the location on this phone: Jeeves listens for
    // positions while it is on screen.
    location.permissionState = LocationPermission.whileInUse;
    // The user is at the office, nowhere near the store.
    location.freshPoint = _elsewhere;

    final now = DateTime.now();
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('c1'),
      title: const Value('Buy hinges'),
      notes: const Value('The long ones'),
      userId: const Value(_userId),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    // A tag hint the clarification must leave alone.
    final area = await db.tagDao.findOrCreateTag('Home', 'area', _userId);
    await db.captureDao.assignTagHint('c1', area, _userId);

    storePlaceId = (await db.placeDao.createNamedPlace(
      name: 'Hardware store',
      latitudeDegrees: _store.latitudeDegrees,
      longitudeDegrees: _store.longitudeDegrees,
      radiusMeters: 150,
      userId: _userId,
    ))!;

    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      locationSourceProvider.overrideWithValue(location),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    await container.read(syncedPreferencesProvider.future);
  });

  tearDown(() async {
    await location.dispose();
    await db.close();
  });

  /// The Inbox, then the Capture's clarify screen — the real route.
  Future<void> openClarify(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    appRouter.go('/inbox');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: appRouter),
      ),
    );
    await _settle(tester);

    await tester.tap(find.text('Buy hinges'));
    await _settle(tester);
  }

  /// Takes the app off screen and lets the watches behind it close.
  ///
  /// The container goes with it: a drift watch left open when the tree goes
  /// leaves a timer pending, and the *next* test would pay for it
  /// (docs/TESTING.md).
  Future<void> closeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  }

  /// Scrolls the Place chip into view and opens the picker.
  ///
  /// The chip sits below the fold and a ListView builds its children lazily,
  /// so the drag comes first: the chip has to exist before it can be tapped.
  Future<void> openPlaceChip(WidgetTester tester) async {
    final chip = find.byKey(const Key('clarify_place_chip'));
    for (var i = 0; i < 15 && chip.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(chip, findsOneWidget,
        reason: 'the Place chip never came into view');
    await tester.ensureVisible(chip);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(chip);
    await _settle(tester);
  }

  /// Routes the Capture to Next, accepting the dialog's seeded phrase.
  Future<void> routeToNext(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Next Action'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('Next Action'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Next Action'));
    await _settle(tester);
    await tester.tap(find.text('Save'));
    await _settle(tester);
  }

  /// Waits for a provider to answer, on the real event loop.
  Future<T> eventually<T>(
    WidgetTester tester,
    ProviderListenable<T> provider,
    bool Function(T) done,
  ) async {
    final sub = container.listen(provider, (_, _) {});
    try {
      for (var i = 0; i < 800; i++) {
        final value = sub.read();
        if (done(value)) return value;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      return sub.read();
    } finally {
      sub.close();
    }
  }

  /// The Outcome the clarification created.
  Future<String> outcomeId(WidgetTester tester) async {
    final ids = await tester.runAsync(
      () => db.captureDao.outcomeIdsForCapture('c1'),
    );
    return ids!.single;
  }

  /// The Outcome's current Action.
  Future<Action> currentAction(WidgetTester tester, String id) async {
    final action = await tester.runAsync(
      () => db.actionDao.getCurrentAction(id),
    );
    return action!;
  }

  /// The Capture, exactly as it was captured.
  Future<void> expectCaptureUntouched(WidgetTester tester) async {
    final result = await tester.runAsync(() async {
      final capture = await db.captureDao.getCapture('c1');
      final hints = await db.captureDao.tagHintsForCapture('c1');
      return (capture: capture, hints: hints);
    });
    final r = result!;
    expect(r.capture!.title, 'Buy hinges');
    expect(r.capture!.notes, 'The long ones');
    expect(r.hints.map((t) => t.name), contains('Home'),
        reason: 'the tag hints are the Capture\'s, not the Outcome\'s');
  }

  testWidgets('a named Place on the clarify card puts the Outcome there',
      (tester) async {
    await openClarify(tester);
    try {
      await openPlaceChip(tester);
      await tester.tap(find.byKey(Key('place_picker_place_$storePlaceId')));
      await _settle(tester);

      expect(find.text('Hardware store'), findsOneWidget,
          reason: 'the chip names the Place the user chose');

      await routeToNext(tester);

      final id = await outcomeId(tester);
      final action = await currentAction(tester, id);
      expect(action.placeId, storePlaceId,
          reason: 'the Action the clarification created is at that Place');
      await expectCaptureUntouched(tester);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('an Outcome at another Place leaves Next and shows on the '
      'place page', (tester) async {
    await openClarify(tester);
    try {
      await openPlaceChip(tester);
      await tester.tap(find.byKey(Key('place_picker_place_$storePlaceId')));
      await _settle(tester);

      await routeToNext(tester);

      final id = await outcomeId(tester);

      // The Place and the location have to be known before Next means
      // anything: with no place known, or no location, nothing is hidden.
      final places = await eventually<AsyncValue<Map<String, ActionPlace>>>(
        tester,
        currentPlacesProvider,
        (v) => v.hasValue && v.value!.containsKey(id),
      );
      expect(places.value![id]!.name, 'Hardware store');
      await eventually<CurrentLocation>(
        tester,
        currentLocationProvider,
        (v) => v is LocationKnown,
      );
      final next = await eventually<AsyncValue<List<Todo>>>(
        tester,
        nextProvider,
        (v) => v.hasValue && !v.value!.any((t) => t.id == id),
      );
      expect(next.value!.map((t) => t.id), isNot(contains(id)),
          reason: 'the user is at the office, nowhere near the store');

      // The place page is where it is to be found.
      final groups = await eventually<AsyncValue<List<PlacePageGroup>>>(
        tester,
        placePageGroupsProvider,
        (v) =>
            v.hasValue &&
            v.value!.any(
              (g) => g.rows.any((r) => r.todo.id == id),
            ),
      );
      final group = groups.value!.firstWhere((g) => g.label == 'Hardware store');
      final row = group.rows.firstWhere((r) => r.todo.id == id);
      expect(row.isOnNext, isFalse);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a pin chosen on the clarify card belongs to that Action '
      'alone, and asks for the location once', (tester) async {
    // The location has not been allowed on this phone yet, so saving the
    // first Place has something to ask about.
    location.permissionState = LocationPermission.denied;
    await openClarify(tester);
    try {
      await openPlaceChip(tester);
      await tester.tap(find.byKey(const Key('place_picker_drop_pin')));
      await _settle(tester);

      await tester.enterText(
        find.byKey(const Key('place_point_coordinates')),
        '52.3702, 4.8952',
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('place_pin_save')));
      await _settle(tester);

      // Dropping a pin is saving a Place: the first one saved may ask for the
      // location, and it asks once.
      expect(find.byKey(const Key('location_permission_allow')), findsOneWidget);
      await tester.tap(find.byKey(const Key('location_permission_allow')));
      await _settle(tester);
      expect(location.permissionRequests, 1);

      await routeToNext(tester);

      final id = await outcomeId(tester);
      final action = await currentAction(tester, id);
      expect(action.placeId, isNotNull);
      final pin = await tester.runAsync(
        () => db.customSelect(
          "SELECT kind FROM places WHERE id = ?",
          variables: [Variable<String>(action.placeId!)],
        ).getSingle(),
      );
      expect(pin!.read<String>('kind'), 'pin',
          reason: 'a pin belongs to that one Action and is nowhere in the '
              'user\'s list of places');
      await expectCaptureUntouched(tester);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a chip left empty clarifies as today, with no Place',
      (tester) async {
    await openClarify(tester);
    try {
      await routeToNext(tester);

      final id = await outcomeId(tester);
      final action = await currentAction(tester, id);
      expect(action.placeId, isNull);

      await eventually<CurrentLocation>(
        tester,
        currentLocationProvider,
        (v) => v is LocationKnown,
      );
      final next = await eventually<AsyncValue<List<Todo>>>(
        tester,
        nextProvider,
        (v) => v.hasValue && v.value!.any((t) => t.id == id),
      );
      expect(next.value!.map((t) => t.id), contains(id),
          reason: 'an Outcome with no Place is on Next as it always was');
      await expectCaptureUntouched(tester);
    } finally {
      await closeApp(tester);
    }
  });
}
