/// What the device calendar hands the app, and the seam it comes through.
///
/// Calendar events are personal data. They are read, held in memory for the life
/// of the screen that shows them, and dropped. They are never stored, synced,
/// put in a preference, exported or logged: nothing in this library or in the
/// code that receives these types may print an event, and [CalendarEvent]
/// deliberately has no `toString`, no `toJson` and no equality on its title.
library;

/// One calendar event, as read for today.
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.isAllDay = false,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
}

/// Why a read produced no events.
enum CalendarReadFailure {
  /// No calendar to read here (web, or a platform with no reader).
  notConnected,

  /// The user did not allow reading the calendar.
  permissionRefused,

  /// The calendar store failed or could not be reached.
  unavailable,
}

/// The result of one read: events, or the reason there are none.
class CalendarReading {
  const CalendarReading.events(List<CalendarEvent> this.events) : failure = null;
  const CalendarReading.failed(CalendarReadFailure this.failure) : events = null;

  final List<CalendarEvent>? events;
  final CalendarReadFailure? failure;
}

/// Reads the device calendar. Read-only by construction: the interface has no
/// write.
abstract class CalendarSource {
  /// False where there is no calendar to read (web): Settings hides the switch.
  bool get isSupported;

  /// Ask the user for permission to read the calendar. True when granted.
  Future<bool> requestPermission();

  /// The events that overlap [from]..[to], without asking for permission.
  Future<CalendarReading> readEvents(DateTime from, DateTime to);
}
