/// The location-unknown journey (issue #55).
///
/// With no location, an Outcome that carries a Place stays on Next and says
/// where it is, and one calm line says Jeeves does not know where the user
/// is. With a location, there is no line. With no placed Outcome, there is
/// no line either.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/action_place_and_time_window.dart';
import 'package:jeeves/models/place_area.dart';
import 'package:jeeves/providers/current_location_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/providers/place_gate_provider.dart';
import 'package:jeeves/screens/next/next_screen.dart';
import 'package:jeeves/services/location_source.dart';

import '../helpers/fake_location_source.dart';

/// The Outcome on Next, and the Place it is at.
final _todo = Todo(
  id: 'o1',
  title: 'Outcome o1',
  doneAt: null,
  createdAt: DateTime(2026, 11, 11),
  intent: 'next',
  userId: 'local',
);

final _place = (
  id: 'p1',
  area: PlaceArea.create(
    latitudeDegrees: 52.3702,
    longitudeDegrees: 4.8952,
    radiusMeters: 150,
  )!,
  name: 'Home',
  isPin: false,
);

void main() {
  late FakeLocationSource location;

  setUp(() {
    location = FakeLocationSource();
  });

  tearDown(() async {
    await location.dispose();
  });

  /// The Next screen, with the given location and the given places.
  Future<void> pumpNext(
    WidgetTester tester, {
    required CurrentLocation current,
    Map<String, ActionPlace>? places,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentLocationProvider
              .overrideWith(() => FixedLocationNotifier(current)),
          locationSourceProvider.overrideWithValue(location),
          nextProvider.overrideWith((_) => Stream.value([_todo])),
          currentPlacesProvider
              .overrideWith((_) => Stream.value(places ?? {'o1': _place})),
        ],
        child: const MaterialApp(home: NextScreen()),
      ),
    );
    await tester.pump();
  }

  testWidgets('with no location the line is shown and the row names the '
      'Place', (tester) async {
    await pumpNext(tester, current: const LocationUnknown());

    expect(find.byKey(const Key('location_unknown_line')), findsOneWidget);
    // The row still says where the Outcome is.
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('with a location there is no line', (tester) async {
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
    await pumpNext(
      tester,
      current: const LocationUnknown(),
      places: const <String, ActionPlace>{},
    );

    expect(find.byKey(const Key('location_unknown_line')), findsNothing);
  });

  testWidgets('a refused permission leaves a button that asks again',
      (tester) async {
    location.permissionState = LocationPermission.denied;
    await pumpNext(tester, current: const LocationUnknown());

    expect(find.byKey(const Key('location_unknown_allow')), findsOneWidget);
    await tester.tap(find.byKey(const Key('location_unknown_allow')));
    await tester.pump();
    expect(location.permissionRequests, 1);
  });
}
