import 'calendar_types.dart';

/// The adapter's test implementation: a calendar held in memory, the same
/// arrangement as the in-memory device key store. A journey test changes
/// [events] (or [permissionGranted], [failure]) between reads to play the part
/// of the user's calendar changing.
class InMemoryCalendarSource implements CalendarSource {
  InMemoryCalendarSource({
    this.events = const [],
    this.permissionGranted = true,
    this.failure,
  });

  List<CalendarEvent> events;
  bool permissionGranted;

  /// When set, every read fails with it (after the permission check).
  CalendarReadFailure? failure;

  int readCount = 0;

  @override
  bool get isSupported => true;

  @override
  Future<bool> requestPermission() async => permissionGranted;

  @override
  Future<CalendarReading> readEvents(DateTime from, DateTime to) async {
    readCount++;
    if (!permissionGranted) {
      return const CalendarReading.failed(CalendarReadFailure.permissionRefused);
    }
    final failed = failure;
    if (failed != null) return CalendarReading.failed(failed);
    return CalendarReading.events([
      for (final event in events)
        if (event.start.isBefore(to) && from.isBefore(event.end)) event,
    ]);
  }
}
