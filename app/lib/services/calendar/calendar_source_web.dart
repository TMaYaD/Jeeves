import 'calendar_types.dart';

/// A platform with no calendar reader: nothing is connected.
class _NoCalendarSource implements CalendarSource {
  const _NoCalendarSource();

  @override
  bool get isSupported => false;

  @override
  Future<bool> requestPermission() async => false;

  @override
  Future<CalendarReading> readEvents(DateTime from, DateTime to) async =>
      const CalendarReading.failed(CalendarReadFailure.notConnected);
}

CalendarSource createPlatformCalendarSource() => const _NoCalendarSource();
