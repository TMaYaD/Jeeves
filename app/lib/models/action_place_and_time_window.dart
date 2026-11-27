/// The Place and the time window an Action carries (issue #239).
///
/// An Action has at most one **Place** — a named one, or a one-time pin — and
/// at most one time: a named **time window**, or the one-time TimeContext. The
/// two are exclusive: setting one clears the other in the same write.
///
/// A reference the app cannot read — a Place that no longer exists, hours that
/// do not parse — resolves to nothing rather than hiding the Action.
library;

import 'place_area.dart';
import 'time_window_hours.dart';

/// The Place an Action carries, resolved from the row it points at.
///
/// [isPin] is true for a one-time pin — a Place that belongs to this one
/// Action and is never listed — and false for a named Place.
typedef ActionPlace = ({
  String id,
  PlaceArea area,
  String? name,
  bool isPin,
});

/// The Place a Habit carries, resolved from the row it points at.
///
/// The same shape as [ActionPlace]: a Habit carries at most one Place, a
/// named one or a one-time pin, and the pin belongs to this one Habit.
typedef HabitPlace = ActionPlace;

/// The time window an Action carries, resolved from the row it points at.
typedef ActionTimeWindow = ({
  String id,
  TimeWindowHours hours,
  String name,
});

/// What an Action resolves to for place and time.
///
/// Either half is null when the Action carries none, when the row it names no
/// longer exists, or when the stored value cannot be read.
typedef ActionPlaceAndTimeWindow = ({
  ActionPlace? place,
  ActionTimeWindow? timeWindow,
});
