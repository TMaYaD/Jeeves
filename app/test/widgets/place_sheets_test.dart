/// The Place sheets lay out at 320 dp (issue #55).
///
/// The phone is 320 dp wide; a sheet that overflows there is a sheet the user
/// cannot use.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/place_gate_provider.dart';
import 'package:jeeves/providers/places_provider.dart';
import 'package:jeeves/widgets/place_editor_sheet.dart';
import 'package:jeeves/widgets/place_pin_sheet.dart';
import 'package:jeeves/widgets/place_picker_sheet.dart';

import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() async {
    db = GtdDatabase(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  testWidgets('the editor lays out at 320 dp', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: Scaffold(body: PlaceEditorSheet()),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('place_editor_name')), findsOneWidget);
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
          currentPlacesProvider
              .overrideWith((_) => Stream.value(const {})),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PlacePickerSheet(outcomeId: 'o1', actionId: 'a1')),
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
}
