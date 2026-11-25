/// The Place and the time window an Action carries (issue #239).
///
/// An Action has at most one **Place** — a named one, or a one-time pin — and
/// at most one time: a named **time window**, or the one-time TimeContext. The
/// two are exclusive: setting one clears the other in the same write.
///
/// A reference the app cannot read — a Place that no longer exists, hours that
/// do not parse — resolves to nothing rather than hiding the Action.
///
/// The hours a named **Place** carries (issue #1074) live here too: a Place
/// has one source of hours, and the resolver is where that rule is written
/// down once.
library;

import 'package:timezone/timezone.dart' as tz;

import 'place_area.dart';
import 'place_time_zone.dart';
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

/// The hours a Place carries, and the clock they are read on.
///
/// A Place has **one** source of hours: a named time window, or hours of its
/// own. [location] is the zone they are read on — null for the phone's clock.
typedef PlaceHours = ({
  String? timeWindowId,
  String? timeWindowName,
  TimeWindowHours hours,
  tz.Location? location,
});

/// The hours a Place gives an Action, and the Place they come from.
///
/// Only a named Place carries hours, and [placeName] is that Place's name.
typedef ActionPlaceHours = ({
  String placeId,
  String placeName,
  PlaceHours hours,
});

/// The hours a Place resolves to, or null when it has none the app can read.
///
/// One rule, in one place:
///
/// - A Place that names a time window takes **that window's** hours. When the
///   window row is gone — [timeWindowHoursText] is null — or its hours do not
///   parse, the Place resolves to nothing.
/// - Otherwise a Place that carries hours of its own takes **those**. When
///   they do not parse, the Place resolves to nothing.
/// - The hours are read on the Place's own clock. No zone means the phone's
///   clock; a zone the tz database does not know resolves to nothing.
///
/// A value the app cannot read never hides anything: a Place that resolves to
/// null has no hours, and no hours hide nothing.
PlaceHours? resolvePlaceHours({
  required String? timeWindowId,
  required String? timeWindowName,
  required String? timeWindowHoursText,
  required String? ownHoursText,
  required String? timeZoneName,
}) {
  final TimeWindowHours hours;
  String? windowId;
  String? windowName;
  if (timeWindowId != null) {
    final parsed = TimeWindowHours.tryParse(timeWindowHoursText);
    // The window is gone, or its hours are not hours: the Place has none.
    if (parsed == null) return null;
    hours = parsed;
    windowId = timeWindowId;
    windowName = timeWindowName;
  } else {
    final parsed = TimeWindowHours.tryParse(ownHoursText);
    if (parsed == null) return null;
    hours = parsed;
  }

  tz.Location? location;
  if (timeZoneName != null) {
    location = placeTimeZoneLocation(timeZoneName);
    // A zone the app cannot read is a value the app cannot read: the Place
    // resolves to nothing rather than to hours on the wrong clock.
    if (location == null) return null;
  }

  return (
    timeWindowId: windowId,
    timeWindowName: windowName,
    hours: hours,
    location: location,
  );
}
