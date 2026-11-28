/// The time zone a place's hours are read on.
///
/// A place carries the IANA name of the zone it is in (`Europe/Berlin`), so
/// its hours open and close on the place's own clock rather than the phone's.
///
/// A zone the app cannot read is a value the app cannot read: it reads as no
/// zone at all, and the hours are then read on the phone's clock, which
/// hides nothing the phone's clock would not hide.
library;

import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// The tz location for the IANA [name] (`Europe/Berlin`), or null when the
/// tz database does not know that name.
///
/// The tz database is loaded on first use, so this works without
/// `NotificationService` having run — on web, on desktop and in tests. The
/// database is global, and loading it resets `tz.local` to UTC, so it is
/// only loaded when it is not loaded yet.
tz.Location? placeTimeZoneLocation(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return null;
  if (!tz.timeZoneDatabase.isInitialized) {
    try {
      tz_data.initializeTimeZones();
    } on tz.TimeZoneInitException {
      return null;
    }
  }
  try {
    return tz.getLocation(trimmed);
  } on tz.LocationNotFoundException {
    return null;
  }
}

/// The names of every zone the tz database knows, in name order.
///
/// The picker for a place's zone shows this list. The database is loaded on
/// first use, so the list is there without `NotificationService` having run.
/// A database that will not load leaves the list empty: there is no zone to
/// offer, and the hours are then read on the phone's clock.
List<String> placeTimeZoneNames() {
  if (!tz.timeZoneDatabase.isInitialized) {
    try {
      tz_data.initializeTimeZones();
    } on tz.TimeZoneInitException {
      return const [];
    }
  }
  return tz.timeZoneDatabase.locations.keys.toList()..sort();
}

/// The city part of an IANA zone name: `America/New_York` reads as
/// `New York`.
///
/// The last segment of the name, with underscores as spaces. A name with no
/// region (`UTC`) reads as itself.
String zoneCityLabel(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '';
  return trimmed.split('/').last.replaceAll('_', ' ');
}
