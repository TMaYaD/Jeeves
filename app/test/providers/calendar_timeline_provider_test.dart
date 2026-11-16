import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/calendar_timeline_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/services/calendar/calendar_types.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fixed morning, so the day the provider reads is exact.
final _now = DateTime(2030, 3, 15, 9, 0);

CalendarEvent _event(String id) => CalendarEvent(
      id: id,
      title: 'Event $id',
      start: DateTime(2030, 3, 15, 9),
      end: DateTime(2030, 3, 15, 10),
    );

/// A calendar source whose reads stay pending until the test completes them, so
/// the test decides what is in flight, and in which order reads finish.
class _ControlledCalendarSource implements CalendarSource {
  final List<Completer<CalendarReading>> pendingReads = [];

  /// When set, the permission request stays pending until it is completed.
  Completer<bool>? pendingPermission;

  @override
  bool get isSupported => true;

  @override
  Future<bool> requestPermission() {
    final pending = pendingPermission;
    if (pending != null) return pending.future;
    return Future<bool>.value(true);
  }

  @override
  Future<CalendarReading> readEvents(DateTime from, DateTime to) {
    final completer = Completer<CalendarReading>();
    pendingReads.add(completer);
    return completer.future;
  }

  /// Finishes the read at [index] with the events called [ids].
  void completeRead(int index, List<String> ids) {
    pendingReads[index].complete(
        CalendarReading.events([for (final id in ids) _event(id)]));
  }
}

/// Lets the pending microtasks and timers run.
Future<void> _flush() async {
  await pumpEventQueue();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({kShowCalendarOnTimelineKey: true});
  });

  ProviderContainer containerWith(_ControlledCalendarSource source) {
    final container = ProviderContainer(overrides: [
      calendarSourceProvider.overrideWithValue(source),
      clockProvider.overrideWithValue(() => _now),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  group('CalendarTimelineNotifier', () {
    test('a read still in flight when the switch goes off does not reconnect '
        'the calendar', () async {
      final source = _ControlledCalendarSource();
      final container = containerWith(source);
      final notifier = container.read(calendarTimelineProvider.notifier);
      expect(await notifier.isSwitchedOn(), isTrue);

      final read = notifier.refresh();
      await _flush();
      expect(source.pendingReads, hasLength(1));

      // The user turns the calendar off while the read is still in flight.
      await notifier.setSwitch(false);
      source.completeRead(0, ['standup']);
      await read;

      final state = container.read(calendarTimelineProvider);
      expect(state.status, CalendarTimelineStatus.notConnected);
      expect(state.events, isEmpty);
    });

    test('an older read that finishes after a newer one does not overwrite '
        'the newer snapshot', () async {
      final source = _ControlledCalendarSource();
      final container = containerWith(source);
      final notifier = container.read(calendarTimelineProvider.notifier);
      expect(await notifier.isSwitchedOn(), isTrue);

      final older = notifier.refresh();
      await _flush();
      final newer = notifier.refresh();
      await _flush();
      expect(source.pendingReads, hasLength(2));

      // The newer read finishes first; the older one finishes afterwards.
      source.completeRead(1, ['newer']);
      await newer;
      source.completeRead(0, ['older']);
      await older;

      final state = container.read(calendarTimelineProvider);
      expect(state.status, CalendarTimelineStatus.ready);
      expect(state.events.map((event) => event.id), ['newer']);
    });

    test('the switch going off while the permission is asked for leaves the '
        'calendar off', () async {
      SharedPreferences.setMockInitialValues({});
      final source = _ControlledCalendarSource();
      source.pendingPermission = Completer<bool>();
      final container = containerWith(source);
      final notifier = container.read(calendarTimelineProvider.notifier);
      expect(await notifier.isSwitchedOn(), isFalse);

      final switchingOn = notifier.setSwitch(true);
      await _flush();

      // The user turns the calendar off again while the dialog is up, and the
      // permission is then refused.
      await notifier.setSwitch(false);
      source.pendingPermission!.complete(false);
      await switchingOn;

      final state = container.read(calendarTimelineProvider);
      expect(state.status, CalendarTimelineStatus.notConnected);
      expect(state.events, isEmpty);
    });
  });
}
