/// The device calendar as the day timeline sees it: a device-local switch, the
/// permission, and today's events held in memory.
///
/// Nothing here is persisted except the switch itself. The events are a value of
/// this notifier's state, dropped when it is disposed; they are never written to
/// the database, a preference, the op log, an export or a log line.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/calendar/calendar_source.dart';
import 'clock_provider.dart';

/// Device-local: the calendar permission is per device, so this is not one of
/// the synced preferences.
const kShowCalendarOnTimelineKey = 'calendar_show_on_timeline';

/// The adapter. Tests override this with an `InMemoryCalendarSource`.
final calendarSourceProvider =
    Provider<CalendarSource>((ref) => createPlatformCalendarSource());

enum CalendarTimelineStatus {
  /// The switch is off, or the platform has no calendar.
  notConnected,

  /// A read is under way. The timeline is usable meanwhile.
  loading,

  /// Events were read; the day window runs to the Evening Shutdown time.
  ready,

  /// The user did not allow reading the calendar.
  permissionRefused,

  /// The calendar could not be read; "Try again" reads it again.
  unavailable,
}

class CalendarTimelineState {
  const CalendarTimelineState({
    this.status = CalendarTimelineStatus.notConnected,
    this.events = const [],
  });

  final CalendarTimelineStatus status;

  /// Today's events. Memory only.
  final List<CalendarEvent> events;

  bool get isConnected => status != CalendarTimelineStatus.notConnected;

  bool sameAs(CalendarTimelineState other) {
    if (status != other.status || events.length != other.events.length) {
      return false;
    }
    for (var i = 0; i < events.length; i++) {
      final a = events[i];
      final b = other.events[i];
      if (a.id != b.id ||
          a.title != b.title ||
          a.start != b.start ||
          a.end != b.end ||
          a.isAllDay != b.isAllDay) {
        return false;
      }
    }
    return true;
  }
}

class CalendarTimelineNotifier extends Notifier<CalendarTimelineState> {
  late final Future<void> _switchLoaded;
  bool _switchOn = false;

  @override
  CalendarTimelineState build() {
    _switchLoaded = _loadSwitch();
    return const CalendarTimelineState();
  }

  Future<void> _loadSwitch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _switchOn = prefs.getBool(kShowCalendarOnTimelineKey) ?? false;
    } on Object {
      // Preferences unavailable: the calendar stays off.
      _switchOn = false;
    }
    if (_switchOn && state.status == CalendarTimelineStatus.notConnected) {
      state = const CalendarTimelineState(status: CalendarTimelineStatus.loading);
    }
  }

  /// Whether the switch is on, once it has been read from the device.
  Future<bool> isSwitchedOn() async {
    await _switchLoaded;
    return _switchOn;
  }

  /// Turns the switch on or off. Turning it on asks for the permission; a
  /// refusal leaves the switch on with the `permissionRefused` state so the
  /// timeline can say so.
  Future<void> setSwitch(bool on) async {
    await _switchLoaded;
    _switchOn = on;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kShowCalendarOnTimelineKey, on);
    if (!on) {
      state = const CalendarTimelineState();
      return;
    }
    state = const CalendarTimelineState(status: CalendarTimelineStatus.loading);
    final granted = await ref.read(calendarSourceProvider).requestPermission();
    if (!granted) {
      state = const CalendarTimelineState(
          status: CalendarTimelineStatus.permissionRefused);
      return;
    }
    await refresh();
  }

  /// Reads today's calendar. Does nothing when the switch is off. A changed
  /// result replaces the state (and so re-flows the timeline); an identical one
  /// leaves it alone.
  Future<void> refresh() async {
    await _switchLoaded;
    if (!_switchOn) return;
    final now = ref.read(clockProvider)();
    final dayStart = DateTime(now.year, now.month, now.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    if (state.status == CalendarTimelineStatus.notConnected) {
      state = const CalendarTimelineState(status: CalendarTimelineStatus.loading);
    }
    final reading =
        await ref.read(calendarSourceProvider).readEvents(dayStart, dayEnd);
    final events = reading.events;
    final next = events != null
        ? CalendarTimelineState(
            status: CalendarTimelineStatus.ready,
            events: List.unmodifiable(events),
          )
        : CalendarTimelineState(
            status: switch (reading.failure) {
              CalendarReadFailure.permissionRefused =>
                CalendarTimelineStatus.permissionRefused,
              CalendarReadFailure.notConnected =>
                CalendarTimelineStatus.notConnected,
              _ => CalendarTimelineStatus.unavailable,
            },
          );
    if (!state.sameAs(next)) state = next;
  }
}

final calendarTimelineProvider =
    NotifierProvider<CalendarTimelineNotifier, CalendarTimelineState>(
  CalendarTimelineNotifier.new,
);

/// The switch as stored on this device, for the Settings row. Separate from the
/// timeline state so the row shows the user's choice even when the permission
/// was refused.
final calendarSwitchProvider = FutureProvider<bool>((ref) async {
  ref.watch(calendarTimelineProvider);
  return ref.read(calendarTimelineProvider.notifier).isSwitchedOn();
});
