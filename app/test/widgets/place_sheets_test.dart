/// The Place sheets lay out at 320 dp, and the picker answers the choice
/// (issue #55, #1078).
///
/// The phone is 320 dp wide; a sheet that overflows there is a sheet the user
/// cannot use. The picker writes nothing: it hands back what the user chose.
library;

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/database/daos/place_dao.dart' show NamedPlaceWithUse;
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/models/place_choice.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_permission_flow.dart';
import 'package:jeeves/providers/phone_time_zone_provider.dart';
import 'package:jeeves/providers/places_provider.dart';
import 'package:jeeves/providers/time_window_provider.dart';
import 'package:jeeves/widgets/place_editor_sheet.dart';
import 'package:jeeves/widgets/place_pin_sheet.dart';
import 'package:jeeves/widgets/place_picker_sheet.dart';

import '../test_helpers.dart';

/// Settles the tree and lets real async work finish: a Drift write inside a
/// widget callback only completes when the real event queue runs
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

  setUp(() async {
    // The location was asked for on this device already: the editor's first
    // save does not ask again, and the test is about the picker's answer.
    SharedPreferences.setMockInitialValues({locationPermissionAskedKey: true});
    db = GtdDatabase(NativeDatabase.memory());
    // An Outcome with a current Action: the Action is where a Place would go,
    // and the picker must leave it alone.
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('o1'),
          title: const Value('Outcome o1'),
          userId: const Value('local'),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db,
        outcomeId: 'o1', text: 'work on o1', userId: 'local');
  });

  tearDown(() async => db.close());

  testWidgets('the editor lays out at 320 dp', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // The editor reads the user's time windows and the phone's own
          // zone. A phone in a test has no timezone plugin, and a widget
          // test has no store to read windows from.
          timeWindowsProvider.overrideWith((_) => Stream.value(const [])),
          phoneTimeZoneNameProvider
              .overrideWith((ref) async => 'Europe/Amsterdam'),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PlaceEditorSheet()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('place_editor_name')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the editor lays out at 320 dp with the hours section',
      (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final hours = TimeWindowHours.create({
      1: (startMinute: 11 * 60, endMinute: 20 * 60),
      2: (startMinute: 11 * 60, endMinute: 20 * 60),
      3: (startMinute: 11 * 60, endMinute: 20 * 60),
      4: (startMinute: 11 * 60, endMinute: 20 * 60),
      5: (startMinute: 11 * 60, endMinute: 20 * 60),
    })!;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          // The editor reads the user's time windows and the phone's own
          // zone. A phone in a test has no timezone plugin, and a widget
          // test has no store to read windows from.
          timeWindowsProvider.overrideWith((_) => Stream.value(const [])),
          phoneTimeZoneNameProvider
              .overrideWith((ref) async => 'Europe/Amsterdam'),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: PlaceEditorSheet(
              place: (
                id: 'p1',
                name: 'Hardware store',
                area: PlaceArea.create(
                  latitudeDegrees: 52.3702,
                  longitudeDegrees: 4.8952,
                  radiusMeters: 150,
                )!,
                useCount: 0,
                hoursLabel: hours.describe(),
                hours: (
                  timeWindowId: null,
                  ownHoursText: hours.encode(),
                  timeZone: 'Europe/Berlin',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // The hours and the zone are on show, and they fit.
    expect(find.byKey(const Key('place_hours_own_label')), findsOneWidget);
    expect(find.byKey(const Key('place_hours_zone_row')), findsOneWidget);
    expect(find.text('Europe/Berlin'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the picker lays out at 320 dp', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          namedPlacesWithUseCountProvider
              .overrideWith((_) => Stream.value(const [])),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PlacePickerSheet(canClear: false)),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('place_picker_search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pin sheet lays out at 320 dp', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: Scaffold(body: PlacePinSheet()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('place_pin_name')), findsOneWidget);
    expect(find.byKey(const Key('place_point_coordinates')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  /// A named Place as the picker lists it.
  NamedPlaceWithUse namedPlace(String id, String name) => (
        id: id,
        name: name,
        area: PlaceArea.create(
          latitudeDegrees: 52.3702,
          longitudeDegrees: 4.8952,
          radiusMeters: 150,
        )!,
        useCount: 0,
        hoursLabel: null,
        hours: (timeWindowId: null, ownHoursText: null, timeZone: null),
      );

  /// Opens the picker from a button, over the given named Places.
  ///
  /// Answers the choice the user made: the future completes when the picker
  /// has been closed.
  Future<Completer<PlaceChoice?>> openPicker(
    WidgetTester tester, {
    required bool canClear,
    List<NamedPlaceWithUse> places = const [],
  }) async {
    final completer = Completer<PlaceChoice?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          namedPlacesWithUseCountProvider
              .overrideWith((_) => Stream.value(places)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  completer.complete(
                      await showPlacePickerSheet(context, canClear: canClear));
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return completer;
  }

  /// The choice the picker made, once the sheet has closed.
  Future<PlaceChoice?> choiceOf(
    WidgetTester tester,
    Completer<PlaceChoice?> completer,
  ) async {
    await tester.pumpAndSettle();
    await tester.pump();
    return completer.future;
  }

  testWidgets('the picker answers the named place the user picks, and writes '
      'nothing', (tester) async {
    final home = namedPlace('p1', 'Home');
    final completer =
        await openPicker(tester, canClear: false, places: [home]);

    await tester.tap(find.byKey(const Key('place_picker_place_p1')));
    final choice = await choiceOf(tester, completer);

    expect(choice, NamedPlaceDraft('p1', 'Home'));

    // The picker wrote nothing: the Action carries no Place, and no pin was
    // made. The choice is the picker's only answer.
    final action =
        await tester.runAsync(() => db.actionDao.getCurrentAction('o1'));
    expect(action!.placeId, isNull);
    final pins = await tester.runAsync(
      () => db.customSelect("SELECT id FROM places WHERE kind = 'pin'").get(),
    );
    expect(pins, isEmpty);
  });

  testWidgets('the picker answers the place the editor saved', (tester) async {
    final completer = await openPicker(tester, canClear: false);

    await tester.tap(find.byKey(const Key('place_picker_new_place')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('place_editor_name')), 'Bakery');
    await tester.enterText(
        find.byKey(const Key('place_point_coordinates')), '52.3702, 4.8952');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place_editor_save')));
    await _settle(tester);
    final choice = await choiceOf(tester, completer);

    final saved = await tester.runAsync(
      () => db.placeDao.watchNamedPlaces().first,
    );
    expect(saved!.single.name, 'Bakery');
    expect(choice, NamedPlaceDraft(saved.single.id, 'Bakery'));
  });

  testWidgets('the picker answers the pin the user drops', (tester) async {
    final completer = await openPicker(tester, canClear: false);

    await tester.tap(find.byKey(const Key('place_picker_drop_pin')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('place_pin_name')), 'Corner shop');
    await tester.enterText(
        find.byKey(const Key('place_point_coordinates')), '52.3702, 4.8952');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place_pin_save')));
    final choice = await choiceOf(tester, completer);

    expect(
      choice,
      PinDraft(
        area: PlaceArea.create(
          latitudeDegrees: 52.3702,
          longitudeDegrees: 4.8952,
          radiusMeters: PlaceArea.defaultRadiusMeters,
        )!,
        name: 'Corner shop',
      ),
    );

    // The pin was not saved either: the picker only carries the choice.
    final pins = await tester.runAsync(
      () => db.customSelect("SELECT id FROM places WHERE kind = 'pin'").get(),
    );
    expect(pins, isEmpty);
  });

  testWidgets('the picker answers a clear when there is a place to clear',
      (tester) async {
    final completer = await openPicker(tester, canClear: true);

    expect(find.byKey(const Key('place_picker_clear')), findsOneWidget);
    await tester.tap(find.byKey(const Key('place_picker_clear')));
    final choice = await choiceOf(tester, completer);

    expect(choice, const ClearPlaceChoice());
  });

  testWidgets('the picker offers no clear when there is no place to clear',
      (tester) async {
    await openPicker(tester, canClear: false);

    expect(find.byKey(const Key('place_picker_clear')), findsNothing);
  });

  testWidgets('the editor answers the name it saved, not one typed while the '
      'save was in flight', (tester) async {
    final answer = Completer<SavedPlace?>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  answer.complete(await showPlaceEditorSheet(context));
              },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The name field keeps the focus when the save starts, so the text can
    // still be typed into it while the write runs.
    await tester.showKeyboard(find.byKey(const Key('place_editor_name')));
    tester.testTextInput.enterText('Bakery');
    await tester.pumpAndSettle();
    await tester.showKeyboard(
        find.byKey(const Key('place_point_coordinates')));
    tester.testTextInput.enterText('52.3702, 4.8952');
    await tester.pumpAndSettle();
    await tester.showKeyboard(find.byKey(const Key('place_editor_name')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('place_editor_save')));

    // The write is in flight. The user keeps typing while it runs: the text
    // goes in without a pump, so it lands before the write comes back.
    tester.testTextInput.enterText('Cafe');
    await _settle(tester);

    // The Place was saved under the name it carried when the save began, and
    // the editor answers that same name: the chip that shows it must not
    // disagree with the store.
    final saved =
        await tester.runAsync(() => db.placeDao.watchNamedPlaces().first);
    expect(saved!.single.name, 'Bakery');
    expect((await answer.future)!.name, 'Bakery');
  });
}
