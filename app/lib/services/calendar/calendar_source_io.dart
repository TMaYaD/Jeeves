import 'package:flutter/services.dart';

import 'calendar_types.dart';

/// Handled by `CalendarPlugin.kt`. Named here so a test can script it.
const MethodChannel calendarChannel = MethodChannel('jeeves/calendar');

/// Reads the Android calendar provider through `CalendarPlugin.kt`.
///
/// No platform branch: every platform with no handler answers with
/// [MissingPluginException], which means "no calendar here".
///
/// Nothing is logged. A failure is mapped to a [CalendarReadFailure] and its
/// message dropped, because a platform error message can carry event fields.
class _ChannelCalendarSource implements CalendarSource {
  const _ChannelCalendarSource();

  @override
  bool get isSupported => true;

  @override
  Future<bool> requestPermission() async {
    try {
      return await calendarChannel.invokeMethod<bool>('requestPermission') ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<CalendarReading> readEvents(DateTime from, DateTime to) async {
    try {
      final rows = await calendarChannel.invokeListMethod<Map<Object?, Object?>>(
        'readEvents',
        <String, Object?>{
          'fromMillis': from.millisecondsSinceEpoch,
          'toMillis': to.millisecondsSinceEpoch,
        },
      );
      return CalendarReading.events([
        for (final row in rows ?? const <Map<Object?, Object?>>[])
          CalendarEvent(
            id: '${row['id']}',
            title: (row['title'] as String?) ?? '',
            start: DateTime.fromMillisecondsSinceEpoch(row['startMillis'] as int),
            end: DateTime.fromMillisecondsSinceEpoch(row['endMillis'] as int),
            isAllDay: (row['allDay'] as bool?) ?? false,
          ),
      ]);
    } on MissingPluginException {
      return const CalendarReading.failed(CalendarReadFailure.notConnected);
    } on PlatformException catch (e) {
      return CalendarReading.failed(
        e.code == 'permission_denied'
            ? CalendarReadFailure.permissionRefused
            : CalendarReadFailure.unavailable,
      );
    } on Object {
      // A malformed row. Not rethrown or printed: it may hold an event field.
      return const CalendarReading.failed(CalendarReadFailure.unavailable);
    }
  }
}

CalendarSource createPlatformCalendarSource() =>
    const _ChannelCalendarSource();
