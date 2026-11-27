/// currentPlaceHoursProvider drops hours that belong to a replaced Action
/// (issue #1074): the hours stream and the current-Action stream emit
/// separately, so for a moment the hours can name an Action that no longer
/// is the Outcome's current one.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/action_place_and_time_window.dart';
import 'package:jeeves/models/current_action.dart';
import 'package:jeeves/models/time_window_hours.dart';
import 'package:jeeves/providers/current_action_provider.dart';
import 'package:jeeves/providers/place_hours_provider.dart';

ActionPlaceHours _hoursFor(String actionId) => (
      actionId: actionId,
      placeId: 'p1',
      placeName: 'Hardware store',
      hours: (
        timeWindowId: null,
        timeWindowName: null,
        hours: TimeWindowHours.create({
          1: (startMinute: 11 * 60, endMinute: 20 * 60),
        })!,
        location: null,
      ),
    );

CurrentAction _current(String actionId) => (
      actionId: actionId,
      actionText: 'Buy screws',
      timeWindow: null,
      timeContext: null,
    );

Future<Map<String, ActionPlaceHours>> _read({
  required Map<String, ActionPlaceHours> hours,
  required Map<String, CurrentAction> current,
}) async {
  final container = ProviderContainer(overrides: [
    placeHoursProvider.overrideWith((ref) => Stream.value(hours)),
    currentActionsProvider.overrideWith((ref) => Stream.value(current)),
  ]);
  addTearDown(container.dispose);
  container.listen(placeHoursProvider, (_, _) {});
  container.listen(currentActionsProvider, (_, _) {});
  await container.read(placeHoursProvider.future);
  await container.read(currentActionsProvider.future);
  return container.read(currentPlaceHoursProvider);
}

void main() {
  test('hours of the current Action apply', () async {
    final result = await _read(
      hours: {'o1': _hoursFor('a1')},
      current: {'o1': _current('a1')},
    );
    expect(result.keys, {'o1'});
  });

  test('hours of a replaced Action do not apply to its successor', () async {
    final result = await _read(
      hours: {'o1': _hoursFor('a1')},
      current: {'o1': _current('a2')},
    );
    expect(result, isEmpty);
  });

  test('nothing applies for an Outcome with no current Action', () async {
    final result = await _read(
      hours: {'o1': _hoursFor('a1')},
      current: const {},
    );
    expect(result, isEmpty);
  });
}
