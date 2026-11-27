/// The hours a named Place gives the Outcomes at it (issue #1074).
///
/// A Place's hours are the Place's own — a named window's hours, or hours of
/// its own — read on the Place's own clock. An Action's **own** time replaces
/// them: a named window or a Time context is the time that Action follows,
/// and the Place's hours do not apply to it.
///
/// Hiding is on Next only, and it does not read the location: an Outcome at a
/// Place with hours leaves Next while those hours are closed, even while the
/// user is standing at the Place.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/action_place_and_time_window.dart';
import 'clock_provider.dart';
import 'current_action_provider.dart';
import 'database_provider.dart';
import 'time_window_provider.dart';

/// The hours of the Place every current Action is at, keyed by Outcome id.
///
/// Straight from the store: an Outcome whose Place carries hours the app
/// cannot read is absent, a one-time pin is absent too — only a named Place
/// carries hours — and so is an Outcome whose Action has a time of its own.
final placeHoursProvider =
    StreamProvider<Map<String, ActionPlaceHours>>((ref) {
  return ref.watch(databaseProvider).actionDao.watchCurrentPlaceHours();
});

/// The hours that apply to each Outcome, keyed by Outcome id.
///
/// The store already leaves out every Outcome whose current Action carries a
/// time of its own — a named window or a Time context, readable or not — so
/// the Place's hours never apply to it (decision D2). This provider is the one
/// every surface reads, so the gate, the chip and the time page agree.
final currentPlaceHoursProvider = Provider<Map<String, ActionPlaceHours>>((ref) {
  final placeHours = ref.watch(placeHoursProvider).value ?? const {};
  final currentActions = ref.watch(currentActionsProvider).value ?? const {};
  // The two streams emit separately. Hours read for an Action that is no
  // longer the Outcome's current one belong to a replaced Action and must not
  // apply to its successor. Until the current Actions arrive, nothing applies.
  return {
    for (final entry in placeHours.entries)
      if (currentActions[entry.key]?.actionId == entry.value.actionId)
        entry.key: entry.value,
  };
});

/// Outcome ids whose Place's hours are closed right now.
///
/// The Next List hides these; Up Next and every other surface ignore the set
/// — a Place's hours hide an Outcome from Next only.
///
/// The gate does not read the location: the Place's hours hide the Outcome
/// whether the user is at the Place or somewhere else. The hours are read on
/// the Place's own clock.
final outsidePlaceHoursOutcomeIdsProvider = Provider<Set<String>>((ref) {
  ref.watch(timeWindowBoundaryTickProvider);
  final now = ref.watch(clockProvider)();
  final placeHours = ref.watch(currentPlaceHoursProvider);
  return {
    for (final entry in placeHours.entries)
      if (!entry.value.hours.hours.isOpenAt(
        now,
        location: entry.value.hours.location,
      ))
        entry.key,
  };
});
