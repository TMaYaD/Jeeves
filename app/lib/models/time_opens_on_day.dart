/// time_opens_on_day — does an Outcome's time open on a given calendar day
/// (GitHub #1099)?
///
/// A named time window opens on a day when it has hours that start on that
/// day; a window that runs past midnight belongs to the day it starts. A Time
/// context opens on a day when its from-date and weekly days allow that day.
///
/// Pure: it reads no clock and no store. Nothing is stored and nothing syncs.
library;

import 'time_context.dart';
import 'time_window_hours.dart';

/// Whether the time opens on [day]'s calendar day, read in local time.
///
/// An Outcome with no time ([windowHours] and [timeContext] both null) always
/// opens. A named window wins over a Time context: an Action carries one time,
/// and the two are exclusive.
bool timeOpensOnDay({
  TimeWindowHours? windowHours,
  TimeContext? timeContext,
  required DateTime day,
}) {
  final local = day.toLocal();
  if (windowHours != null) {
    return windowHours.hoursForDay(local.weekday) != null;
  }
  if (timeContext != null) {
    return timeContext.allowedIntervalOn(local) != null;
  }
  return true;
}
