import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import 'database_provider.dart';
import 'place_gate_provider.dart';
import 'place_hours_provider.dart';
import 'tag_filter_provider.dart';
import 'time_context_provider.dart';
import 'time_window_provider.dart';

export '../database/gtd_database.dart' show Capture, Todo;

/// Stream of next-action todos.
///
/// Automatically filtered by the active context tag set from
/// [tagFilterProvider] (AND semantics when multiple tags are selected).
///
/// Outcomes whose current Action's TimeContext is not satisfied right now, or
/// whose current Action's named time window is closed right now, are hidden
/// ([outsideTimeContextOutcomeIdsProvider],
/// [outsideTimeWindowOutcomeIdsProvider]); they come back on their own.
///
/// Outcomes whose current Action is at a Place that carries hours are hidden
/// while those hours are closed ([outsidePlaceHoursOutcomeIdsProvider]); they
/// come back when the Place opens.
///
/// Outcomes whose current Action is at a Place the user is not at are hidden
/// too ([awayFromPlaceOutcomeIdsProvider]); they come back when the user
/// arrives. With no location, nothing is hidden by place.
///
/// Hiding is on Next only: Daily Planning's Up Next applies the rule of the
/// day being planned, and Add to Plan reads the Time context set alone.
final nextProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  final outside = {
    ...ref.watch(outsideTimeContextOutcomeIdsProvider),
    ...ref.watch(outsideTimeWindowOutcomeIdsProvider),
    ...ref.watch(outsidePlaceHoursOutcomeIdsProvider),
  };
  final away = ref.watch(awayFromPlaceOutcomeIdsProvider);
  return db.todoDao.watchNext(tagIds: tagIds).map((all) =>
      away.isEmpty && outside.isEmpty
          ? all
          : all
              .where((t) => !outside.contains(t.id) && !away.contains(t.id))
              .toList());

});

/// Stream of waiting-for todos (todos with at least one person-typed tag).
///
/// Automatically filtered by the active context tag set from
/// [tagFilterProvider] (AND semantics when multiple tags are selected).
final waitingForProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.todoDao.watchPersonTagged(tagIds: tagIds);
});

/// Stream of waiting-for todos grouped by person-tag.
///
/// Each entry maps a person [Tag] to the list of active todos assigned to
/// that person. A todo with two person-tags appears under both keys.
/// Tags are ordered alphabetically; todos within each group are ordered by
/// creation date.
///
/// Automatically filtered by the active context tag set from
/// [tagFilterProvider] (AND semantics when multiple tags are selected).
final waitingListGroupedProvider = StreamProvider<Map<Tag, List<Todo>>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.todoDao.watchPersonTaggedGrouped(tagIds: tagIds);
});

/// Stream of maybe-intent todos (intent = 'maybe', done_at IS NULL).
final somedayMaybeProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.todoDao.watchSomedayMaybe(tagIds: tagIds);
});

/// Stream of every active Outcome tagged with the Project [projectTagId],
/// whether it is on the Next List, Waiting For or Maybe.
///
/// Deliberately ignores [tagFilterProvider]: the Project page is a place of
/// its own, not a filtered view of Next.
final projectOutcomesProvider =
    StreamProvider.family<List<Todo>, String>((ref, projectTagId) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchByProject(projectTagId);
});

/// Stream of completed todos ordered by done_at descending.
final doneProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchDone();
});

/// Stream of trashed Outcomes (intent = 'trash'), newest-trashed first.
///
/// Deliberately ignores [tagFilterProvider], like [doneProvider]: the Trash
/// surface is a record of discarded Outcomes, not a working list.
final trashProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchTrash();
});

/// Stream of the whole Inbox — Captures with `clarified_at IS NULL` — newest
/// first, with no context tag filter.
///
/// Unlike [inboxItemsProvider], this ignores [tagFilterProvider] so it covers
/// the user's entire Inbox. Used by the Daily Planning Cadence Trigger to
/// decide whether there is anything to plan.
final unfilteredInboxProvider = StreamProvider<List<Capture>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.captureDao.watchInbox();
});

/// Stream of next-action todos — no context tag filter.
///
/// Unlike [nextProvider], this ignores [tagFilterProvider] so it covers
/// the user's full next-action list. Used by the Daily Planning Cadence Trigger to
/// decide whether there is anything to plan.
final unfilteredNextProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchNext();
});

/// Stream of waiting-for todos — no context tag filter.
///
/// Unlike [waitingForProvider], this ignores [tagFilterProvider] so it covers
/// the user's full waiting-for list. Used by the Weekly Review Content-state Trigger to decide
/// whether the empty-actionable trigger should fire.
final unfilteredWaitingForProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchPersonTagged();
});

/// Stream of maybe-intent todos — no context tag filter.
///
/// Unlike [somedayMaybeProvider], this ignores [tagFilterProvider] so it covers the
/// user's full someday/maybe list. Used by the Weekly Review Content-state Trigger to decide
/// whether the empty-actionable trigger should fire.
final unfilteredSomedayMaybeProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchSomedayMaybe();
});
