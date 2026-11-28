import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timezone/timezone.dart' as tz;

import '../database/gtd_database.dart' show Todo;
import '../models/action_place_and_time_window.dart';
import '../models/time_context.dart';
import 'clock_provider.dart';
import 'database_provider.dart';
import 'place_hours_provider.dart';
import 'tag_filter_provider.dart';
import 'time_context_provider.dart';
import 'time_window_provider.dart';

/// One Outcome on the time page, with the marker that says when it can be
/// done: "On Next" when its time is satisfied now, otherwise when it opens.
typedef TimePageRow = ({
  Todo todo,
  bool isOnNext,
  String marker,
});

/// A group of Outcomes that share a time: one named window, or the one-time
/// times.
typedef TimePageGroup = ({
  String id,
  String title,
  String? hours,
  List<TimePageRow> rows,
});

/// The Next list **before** the time hides anything: the Outcomes the time
/// page shows. The Label filter applies, as it does on Next.
final nextBeforeHidingProvider = StreamProvider<List<Todo>>((ref) {
  final db = ref.watch(databaseProvider);
  final tagIds = ref.watch(tagFilterProvider);
  return db.todoDao.watchNext(tagIds: tagIds);
});

/// Every Outcome on Next that carries a time, grouped by the time it carries
/// (issue #55). With place hours (issue #1074), grouped by place when the
/// action has a place with hours and no own time.
///
/// The list is read **before** the time hides anything, so an Outcome whose
/// window is closed is here rather than gone: the page is where the user sees
/// what the clock is holding back.
final timePageGroupsProvider =
    Provider<AsyncValue<List<TimePageGroup>>>((ref) {
  final next = ref.watch(nextBeforeHidingProvider);
  final windows = ref.watch(currentTimeWindowsProvider);
  final contexts = ref.watch(currentTimeContextsProvider);
  final placeHours = ref.watch(currentPlaceHoursProvider);
  // Re-group when a window opens, a Time context is satisfied, or place hours
  // change (they open/close or the user modifies them).
  ref.watch(timeWindowBoundaryTickProvider);
  ref.watch(timeContextBoundaryTickProvider);
  final now = ref.watch(clockProvider)();
  return next.whenData((todos) => _grouped(
        todos,
        windows.value ?? const <String, ActionTimeWindow>{},
        contexts.value ?? const <String, TimeContext>{},
        placeHours,
        now,
      ));
});

const _dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

List<TimePageGroup> _grouped(
  List<Todo> todos,
  Map<String, ActionTimeWindow> windows,
  Map<String, TimeContext> contexts,
  Map<String, ActionPlaceHours> placeHours,
  DateTime now,
) {
  final byWindow = <String, List<TimePageRow>>{};
  final byPlace = <String, (String placeName, PlaceHours hours, List<TimePageRow> rows)>{};
  final oneTime = <TimePageRow>[];
  for (final todo in todos) {
    final window = windows[todo.id];
    if (window != null) {
      (byWindow[window.id] ??= []).add(_windowRow(todo, window, now));
      continue;
    }
    final context = contexts[todo.id];
    if (context != null) {
      oneTime.add(_contextRow(todo, context, now));
      continue;
    }
    final place = placeHours[todo.id];
    if (place != null) {
      final key = place.placeId;
      final existing = byPlace[key];
      if (existing == null) {
        byPlace[key] = (place.placeName, place.hours, []);
      }
      byPlace[key]!.$3.add(_placeHoursRow(todo, place.hours, now));
    }
  }

  final groups = <TimePageGroup>[];
  // The windows are keyed by Outcome; the groups are keyed by the window
  // itself, and one window may carry several Outcomes.
  final windowById = <String, ActionTimeWindow>{
    for (final window in windows.values) window.id: window,
  };
  final usedWindows = byWindow.keys
      .map((id) => windowById[id])
      .whereType<ActionTimeWindow>()
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  for (final window in usedWindows) {
    groups.add((
      id: window.id,
      title: window.name,
      hours: window.hours.describe(),
      rows: byWindow[window.id]!,
    ));
  }

  // Add place groups sorted by place name.
  final usedPlaces = byPlace.entries.toList()
    ..sort((a, b) => a.value.$1.compareTo(b.value.$1));
  for (final entry in usedPlaces) {
    final (placeName, placeHoursData, rows) = entry.value;
    groups.add((
      id: 'place:${entry.key}',
      title: placeName,
      hours: placeHoursData.hours.describe(),
      rows: rows,
    ));
  }

  if (oneTime.isNotEmpty) {
    groups.add((id: 'one-time', title: 'One-time', hours: null, rows: oneTime));
  }
  return groups;
}

/// A row for an Outcome whose current Action carries a named window.
TimePageRow _windowRow(
  Todo todo,
  ActionTimeWindow window,
  DateTime now,
) {
  if (window.hours.isOpenAt(now)) {
    return (todo: todo, isOnNext: true, marker: 'On Next');
  }
  final next = window.hours.nextTransitionAfter(now);
  return (
    todo: todo,
    isOnNext: false,
    marker: next == null ? 'opens later' : 'opens ${_when(next, now)}',
  );
}

/// A row for an Outcome whose current Action carries a one-time Time context.
TimePageRow _contextRow(Todo todo, TimeContext context, DateTime now) {
  if (context.isSatisfiedAt(now)) {
    return (todo: todo, isOnNext: true, marker: 'On Next');
  }
  final today = DateTime(now.year, now.month, now.day);
  final from = context.fromDate;
  if (from != null && from.isAfter(today)) {
    return (
      todo: todo,
      isOnNext: false,
      marker: 'after ${_monthNames[from.month - 1]} ${from.day}',
    );
  }
  final next = context.nextTransitionAfter(now);
  if (next == null) {
    return (todo: todo, isOnNext: false, marker: 'opens later');
  }
  // A weekly window without hours is open for the whole day it names.
  if (context.startMinute == null) {
    return (
      todo: todo,
      isOnNext: false,
      marker: 'opens ${_dayNames[next.toLocal().weekday - 1]}',
    );
  }
  return (
    todo: todo,
    isOnNext: false,
    marker: 'opens ${_when(next, now)}',
  );
}

/// A row for an Outcome whose place carries hours and the Action has no own time.
TimePageRow _placeHoursRow(Todo todo, PlaceHours hours, DateTime now) {
  if (hours.hours.isOpenAt(now, location: hours.location)) {
    return (todo: todo, isOnNext: true, marker: 'On Next');
  }
  final next = hours.hours.nextTransitionAfter(now, location: hours.location);
  return (
    todo: todo,
    isOnNext: false,
    marker: next == null ? 'opens later' : 'opens ${_whenOnLocation(next, now, hours.location)}',
  );
}

/// When the time opens: the clock alone when it opens today, the day and the
/// clock when it does not.
String _when(DateTime at, DateTime now) {
  final local = at.toLocal();
  final clock = '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return clock;
  }
  return '${_dayNames[local.weekday - 1]} $clock';
}

/// When a place's time opens: format on the place's clock. [at] already
/// carries the place's date and clock; [now] is converted to the same zone
/// before the dates are compared, so a place a day ahead of the phone does not
/// get a weekday for a time that opens today on its own clock.
String _whenOnLocation(DateTime at, DateTime now, tz.Location? location) {
  final clock = '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
  final placeNow = location == null ? now.toLocal() : tz.TZDateTime.from(now, location);
  if (at.year == placeNow.year &&
      at.month == placeNow.month &&
      at.day == placeNow.day) {
    return clock;
  }
  return '${_dayNames[at.weekday - 1]} $clock';
}
