import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart' show Todo;
import 'package:jeeves/models/autoflow.dart';
import 'package:jeeves/models/day_timeline.dart';

Todo _todo(String id, {int? estimate, String? doneAt}) => Todo(
      id: id,
      title: id,
      createdAt: DateTime(2030),
      intent: 'next',
      userId: 'local',
      timeEstimate: estimate,
      doneAt: doneAt,
    );

DateTime _at(int hour, [int minute = 0]) => DateTime(2030, 3, 15, hour, minute);

DayTimelineEntry _entry(String id, int minutes,
        {DateTime? pinned, bool engaged = false}) =>
    DayTimelineEntry(
      outcomeId: id,
      title: id,
      estimateMinutes: minutes,
      pinnedStartAt: pinned,
      isEngaged: engaged,
    );

DayLayout _flow(LastDayLayout last, List<DayTimelineEntry> entries,
        {required DateTime now, String scope = 'day'}) =>
    flowDay(
      scope: scope,
      last: last,
      now: now,
      flowOrigin: _at(9),
      availableMinutes: 240,
      chunkUnitMinutes: 23,
      entries: entries,
    );

void main() {
  group('roundUpToFiveMinutes', () {
    test('rounds a minute past up to the next five', () {
      expect(roundUpToFiveMinutes(_at(9, 1)), _at(9, 5));
      expect(roundUpToFiveMinutes(_at(9, 56)), _at(10));
    });

    test('keeps an exact multiple and drops its seconds', () {
      expect(roundUpToFiveMinutes(_at(9, 45)), _at(9, 45));
      expect(roundUpToFiveMinutes(DateTime(2030, 3, 15, 9, 45, 30)),
          _at(9, 50));
    });
  });

  group('dayTimelineEntriesFor', () {
    test('counts an Outcome with no estimate at the default', () {
      final entries = dayTimelineEntriesFor(
        tasks: [_todo('a', estimate: 30), _todo('b')],
        defaultEstimateMinutes: 10,
        now: _at(9),
      );
      expect(entries[0].estimateMinutes, 30);
      expect(entries[0].isDefaultEstimate, isFalse);
      expect(entries[1].estimateMinutes, 10);
      expect(entries[1].isDefaultEstimate, isTrue);
    });

    test('ignores a time set on an earlier day', () {
      final entries = dayTimelineEntriesFor(
        tasks: [_todo('a', estimate: 30), _todo('b', estimate: 30)],
        defaultEstimateMinutes: 10,
        now: _at(9),
        pinnedStarts: {
          'a': DateTime(2030, 3, 14, 15),
          'b': _at(15),
        },
      );
      expect(entries[0].pinnedStartAt, isNull);
      expect(entries[1].pinnedStartAt, _at(15));
    });

    test('treats a done, running or logged Outcome as engaged', () {
      final entries = dayTimelineEntriesFor(
        tasks: [
          _todo('done', estimate: 10, doneAt: '2030-03-15T09:00:00Z'),
          _todo('running', estimate: 10),
          _todo('logged', estimate: 10),
          _todo('idle', estimate: 10),
        ],
        defaultEstimateMinutes: 10,
        now: _at(9),
        runningTaskId: 'running',
        engagedTaskIds: {'logged'},
      );
      expect(entries.map((e) => e.isEngaged), [true, true, true, false]);
    });
  });

  group('flowDay', () {
    test('with no last layout, flows every entry from the origin', () {
      final layout = _flow(
          LastDayLayout(), [_entry('a', 30), _entry('b', 45)],
          now: _at(9));
      expect(layout.entryFor('a').pieces.single.start, _at(9));
      expect(layout.entryFor('b').pieces.single.start, _at(9, 30));
    });

    test('a changed input re-flows only what has not started or engaged', () {
      final last = LastDayLayout();
      _flow(last, [_entry('a', 30), _entry('b', 30), _entry('c', 30)],
          now: _at(9));
      // At 9:40 `a` (9:00) and `b` (9:30) have started; `c` (10:00) has not.
      // `a` grows, which would push everything after it; the started ones stay.
      final layout = _flow(
          last, [_entry('a', 30), _entry('b', 30), _entry('c', 30)],
          now: _at(9, 40));
      expect(layout.entryFor('a').pieces.single.start, _at(9));
      expect(layout.entryFor('b').pieces.single.start, _at(9, 30));
      expect(layout.entryFor('c').pieces.single.start, _at(10));
    });

    test('a started tile does not move when an earlier entry is removed', () {
      final last = LastDayLayout();
      _flow(last, [_entry('a', 30), _entry('b', 30)], now: _at(9));
      final layout =
          _flow(last, [_entry('b', 30)], now: _at(9, 40));
      expect(layout.entryFor('b').pieces.single.start, _at(9, 30),
          reason: 'b started at 9:30, before now');
    });

    test('an unstarted tile moves up when an earlier entry is removed', () {
      final last = LastDayLayout();
      _flow(last, [_entry('a', 30), _entry('b', 30)], now: _at(9));
      final layout = _flow(last, [_entry('b', 30)], now: _at(9, 5));
      // b's placement at 9:30 is after now, so it re-flows into the free time.
      expect(layout.entryFor('b').pieces.single.start, _at(9, 5));
    });

    test('an engaged tile keeps its place even when it has not started', () {
      final last = LastDayLayout();
      _flow(last, [_entry('a', 30), _entry('b', 30)], now: _at(9));
      final layout = _flow(
          last, [_entry('b', 30, engaged: true)],
          now: _at(9, 5));
      expect(layout.entryFor('b').pieces.single.start, _at(9, 30));
    });

    test('a time the user set is a fixed block the others flow around', () {
      final layout = _flow(
          LastDayLayout(),
          [_entry('a', 60), _entry('b', 30, pinned: _at(9, 30))],
          now: _at(9));
      final b = layout.entryFor('b').pieces.single;
      expect(b.start, _at(9, 30));
      expect(b.isPinned, isTrue);
      expect(layout.entryFor('a').pieces.single.start, _at(10));
    });

    test('a layout remembered for another scope is not reused', () {
      final last = LastDayLayout();
      _flow(last, [_entry('a', 30), _entry('b', 30)], now: _at(9));
      final layout = _flow(last, [_entry('b', 30)],
          now: _at(9, 40), scope: 'another day');
      expect(layout.entryFor('b').pieces.single.start, _at(9));
    });

    test('an entry no gap can hold is flagged and kept', () {
      final layout = flowDay(
        scope: 'day',
        last: LastDayLayout(),
        now: _at(9),
        flowOrigin: _at(9),
        availableMinutes: 30,
        chunkUnitMinutes: 23,
        entries: [_entry('a', 30), _entry('b', 30)],
      );
      expect(layout.entries.map((e) => e.outcomeId), ['a', 'b']);
      expect(layout.entryFor('b').status, PlacementStatus.unplaced);
      expect(layout.entryFor('b').unplacedMinutes, 30);
    });
  });
}
