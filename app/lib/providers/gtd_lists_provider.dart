import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import 'database_provider.dart';
import 'tag_filter_provider.dart';

export '../database/gtd_database.dart' show Todo;

/// Stream of inbox todos (clarified = false), newest first.
///
/// Automatically filtered by the active context tag set from
/// [tagFilterProvider] (AND semantics when multiple tags are selected).
final inboxProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.inboxDao.watchInbox(tagIds: tagIds);
});

/// Stream of next-action todos.
///
/// Automatically filtered by the active context tag set from
/// [tagFilterProvider] (AND semantics when multiple tags are selected).
final nextProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.todoDao.watchNext(tagIds: tagIds);
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
final waitingListGroupedProvider = StreamProvider<Map<Tag, List<Todo>>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchPersonTaggedGrouped();
});

/// Stream of maybe-intent todos (intent = 'maybe', done_at IS NULL).
final maybeProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.todoDao.watchMaybe(tagIds: tagIds);
});

/// Stream of completed todos ordered by done_at descending.
final doneProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchDone();
});

/// Stream of inbox todos (clarified = false), newest first — no context tag filter.
///
/// Unlike [inboxProvider], this ignores [tagFilterProvider] so it covers the
/// user's entire inbox. Used by the Daily Planning Cadence Trigger to decide whether
/// there is anything to plan.
final unfilteredInboxProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.inboxDao.watchInbox();
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
/// Unlike [maybeProvider], this ignores [tagFilterProvider] so it covers the
/// user's full someday/maybe list. Used by the Weekly Review Content-state Trigger to decide
/// whether the empty-actionable trigger should fire.
final unfilteredMaybeProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  return db.todoDao.watchMaybe();
});
