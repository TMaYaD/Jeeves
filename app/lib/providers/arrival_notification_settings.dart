/// The Places the user asked to hear about on arrival (issue #1092).
///
/// The record is device-local: the ids live in shared preferences and are
/// never synced. A Place the user named on one phone is not a Place to
/// arrive at on another, and the permission that makes an arrival possible
/// belongs to the phone anyway.
///
/// The record says which Places the user has switched on. It does not say
/// whether the phone still allows the location — the OS does, and the switch
/// shows on only when both agree.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The device-local key holding the ids of the switched-on Places.
const String arrivalNotificationPlaceIdsKey = 'arrival_notification_place_ids';

/// The ids of the Places whose arrival switch is on, on this device.
final arrivalPlaceIdsProvider =
    AsyncNotifierProvider<ArrivalPlaceIdsNotifier, Set<String>>(
  ArrivalPlaceIdsNotifier.new,
);

/// The device-local record of the switched-on Places.
class ArrivalPlaceIdsNotifier extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(arrivalNotificationPlaceIdsKey);
    if (stored == null || stored.isEmpty) return const <String>{};
    return Set<String>.unmodifiable(stored);
  }

  /// Turns the arrival switch on for [placeId].
  Future<void> turnOn(String placeId) =>
      _write((ids) => <String>{...ids, placeId});

  /// Turns the arrival switch off for [placeId]. The Place stays; only the
  /// switch goes.
  Future<void> turnOff(String placeId) => _remove(placeId);

  /// Forgets [placeId] for good: the Place is gone, so its id must not come
  /// back with the next write.
  Future<void> forget(String placeId) => _remove(placeId);

  /// Writes the record, keeping the stored ids and the ones Jeeves is
  /// changing in step.
  Future<void> _write(Set<String> Function(Set<String> ids) change) async {
    final current = state.asData?.value ?? await future;
    final next = change(current);
    state = AsyncData(Set<String>.unmodifiable(next));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      arrivalNotificationPlaceIdsKey,
      next.toList(growable: false),
    );
  }

  /// Takes [placeId] out of the record.
  Future<void> _remove(String placeId) =>
      _write((ids) => <String>{...ids}..remove(placeId));
}
