import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/day_timeline.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/widgets/day_timeline/day_timeline.dart';

/// A Friday at 09:00, so a weekly window on another day is not today.
final _origin = DateTime(2030, 3, 15, 9);

DayTimelineEntry _entry(
  String id,
  int minutes, {
  DateTime? pinned,
  TimeContext? timeContext,
  bool isDone = false,
  bool isRunning = false,
}) =>
    DayTimelineEntry(
      outcomeId: id,
      title: 'Title $id',
      estimateMinutes: minutes,
      pinnedStartAt: pinned,
      timeContext: timeContext,
      isDone: isDone,
      isRunning: isRunning,
      isEngaged: isDone || isRunning,
    );

class _Calls {
  final pins = <(String, DateTime?)>[];
}

/// A Sprint recorded on [outcomeId], at [startedAt] local time.
TileSprintMark _sprint(
  String id,
  String outcomeId, {
  DateTime? startedAt,
  DateTime? endedAt,
}) =>
    TileSprintMark(
      id: id,
      outcomeId: outcomeId,
      startedAt: startedAt ?? DateTime(2030, 3, 15, 9, 10),
      endedAt: endedAt,
    );

Widget _app(
  List<DayTimelineEntry> entries, {
  int availableMinutes = 240,
  DateTime? now,
  _Calls? calls,
  String scope = 'test',
  List<TileSprintMark> sprints = const [],
}) {
  return ProviderScope(
    overrides: [clockProvider.overrideWithValue(() => now ?? _origin)],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: DayTimeline(
            scope: scope,
            entries: entries,
            flowOrigin: _origin,
            availableMinutes: availableMinutes,
            chunkUnitMinutes: 23,
            sprintMarks: sprints,
            onSetPinnedStart: (id, startAt) async =>
                calls?.pins.add((id, startAt)),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a short and a long estimate each draw one tile, no sub-blocks',
      (tester) async {
    await tester.pumpWidget(_app([_entry('short', 15), _entry('long', 180)]));

    expect(find.byKey(const Key('day_timeline_tile_short_1')), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_tile_long_1')), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_tile_long_2')), findsNothing);
    expect(find.byKey(const Key('day_timeline_tray')), findsNothing);
  });

  testWidgets('an entry split around a set time is drawn as part 1 and part 2',
      (tester) async {
    // The set time leaves two 30-minute gaps; 50 minutes fits neither whole.
    await tester.pumpWidget(_app([
      _entry('blocker', 60, pinned: DateTime(2030, 3, 15, 9, 30)),
      _entry('split', 50),
    ], availableMinutes: 120));

    expect(find.byKey(const Key('day_timeline_tile_split_1')), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_tile_split_2')), findsOneWidget);
    expect(find.textContaining('part 1'), findsOneWidget);
    expect(find.textContaining('part 2'), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_tray')), findsNothing);
  });

  testWidgets('an entry that cannot be wholly placed is listed in the tray',
      (tester) async {
    await tester.pumpWidget(_app([
      _entry('blocker', 60, pinned: DateTime(2030, 3, 15, 9, 30)),
      _entry('big', 100),
    ], availableMinutes: 120));

    expect(find.byKey(const Key('day_timeline_tray')), findsOneWidget);
    expect(find.text('Not wholly placed'), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_tray_set_time_big')),
        findsOneWidget);
    // Whatever fit is still drawn.
    expect(find.byKey(const Key('day_timeline_tile_big_1')), findsOneWidget);
  });

  testWidgets('an Outcome whose Time context allows no time today is flagged',
      (tester) async {
    final notToday = TimeContext.tryParse(jsonEncode({
      'days': [6]
    }))!;
    await tester.pumpWidget(_app([
      _entry('later', 30, timeContext: notToday),
    ]));

    expect(find.byKey(const Key('day_timeline_tray')), findsOneWidget);
    expect(find.text('Its time context allows no time today.'),
        findsOneWidget);
    expect(find.byKey(const Key('day_timeline_tile_later_1')), findsNothing);
  });

  testWidgets('Set the time from the tray hands the chosen start back',
      (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_app([
      _entry('blocker', 60, pinned: DateTime(2030, 3, 15, 9, 30)),
      _entry('big', 100),
    ], availableMinutes: 120, calls: calls));

    await tester.tap(find.byKey(const Key('day_timeline_tray_set_time_big')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('set_time_value')), findsOneWidget);

    await tester.tap(find.byKey(const Key('set_time_later')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('set_time_confirm')));
    await tester.tap(find.byKey(const Key('set_time_confirm')));
    await tester.pumpAndSettle();

    expect(calls.pins, hasLength(1));
    expect(calls.pins.single.$1, 'big');
    expect(calls.pins.single.$2, isNotNull);
  });

  testWidgets('tapping a tile opens the sheet, and a set time can be cleared',
      (tester) async {
    final calls = _Calls();
    await tester.pumpWidget(_app(
        [_entry('a', 30, pinned: DateTime(2030, 3, 15, 10))],
        calls: calls));

    await tester.tap(find.byKey(const Key('day_timeline_tile_a_1')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('set_time_clear')));
    await tester.tap(find.byKey(const Key('set_time_clear')));
    await tester.pumpAndSettle();

    expect(calls.pins, [('a', null)]);
  });

  testWidgets('a tile with no set time offers no way to clear one',
      (tester) async {
    await tester.pumpWidget(_app([_entry('a', 30)]));

    await tester.tap(find.byKey(const Key('day_timeline_tile_a_1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('set_time_clear')), findsNothing);
  });

  testWidgets('dropping a tile on the timeline opens the sheet', (tester) async {
    await tester.pumpWidget(_app([_entry('a', 30), _entry('b', 30)]));

    final gesture = await tester
        .startGesture(tester.getCenter(find.byKey(const Key('day_timeline_tile_a_1'))));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, 90));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('set_time_value')), findsOneWidget);
  });

  testWidgets('planning more than the free time shows the overbooked notice',
      (tester) async {
    await tester.pumpWidget(
        _app([_entry('a', 60), _entry('b', 60)], availableMinutes: 90));

    expect(find.byKey(const Key('day_timeline_overbooked_notice')),
        findsOneWidget);
    expect(find.textContaining('Over by 30m'), findsOneWidget);
  });

  testWidgets('a plan inside the free time shows no overbooked notice',
      (tester) async {
    await tester.pumpWidget(_app([_entry('a', 60)], availableMinutes: 120));

    expect(find.byKey(const Key('day_timeline_overbooked_notice')),
        findsNothing);
    expect(find.textContaining('1h planned of 2h free'), findsOneWidget);
  });

  testWidgets('tile states: done, running and past-and-not-started',
      (tester) async {
    await tester.pumpWidget(_app([
      _entry('done', 60, isDone: true),
      _entry('running', 60, isRunning: true),
      _entry('missed', 60),
      _entry('ahead', 60),
    ], now: DateTime(2030, 3, 15, 12, 30)));

    expect(find.textContaining('Done'), findsOneWidget);
    expect(find.textContaining('Running'), findsOneWidget);
    // 'missed' sits at 11:00-12:00, after done and running; now is 12:30.
    expect(find.textContaining('Not started'), findsOneWidget);
  });

  testWidgets('a Sprint is drawn in the lane and counted on its tile',
      (tester) async {
    await tester.pumpWidget(_app([
      _entry('a', 60),
    ], sprints: [
      _sprint('s1', 'a',
          startedAt: DateTime(2030, 3, 15, 9, 10),
          endedAt: DateTime(2030, 3, 15, 9, 33)),
    ]));

    expect(find.byKey(const Key('day_timeline_sprint_lane')), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_sprint_s1')), findsOneWidget);
    expect(find.textContaining('1 sprint · 23m'), findsOneWidget);
  });

  testWidgets('two Sprints on one Outcome are counted as two', (tester) async {
    await tester.pumpWidget(_app([
      _entry('a', 60),
    ], sprints: [
      _sprint('s1', 'a',
          startedAt: DateTime(2030, 3, 15, 9, 10),
          endedAt: DateTime(2030, 3, 15, 9, 33)),
      _sprint('s2', 'a',
          startedAt: DateTime(2030, 3, 15, 9, 40),
          endedAt: DateTime(2030, 3, 15, 10, 3)),
    ]));

    expect(find.byKey(const Key('day_timeline_sprint_s1')), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_sprint_s2')), findsOneWidget);
    expect(find.textContaining('2 sprints · 46m'), findsOneWidget);
  });

  testWidgets('a running Sprint counts the time since it started',
      (tester) async {
    await tester.pumpWidget(_app([
      _entry('a', 60),
    ], now: DateTime(2030, 3, 15, 9, 40), sprints: [
      _sprint('s1', 'a', startedAt: DateTime(2030, 3, 15, 9, 10)),
    ]));

    expect(find.textContaining('1 sprint · 30m'), findsOneWidget);
  });

  testWidgets('a Sprint of another day is not part of this day',
      (tester) async {
    await tester.pumpWidget(_app([
      _entry('a', 60),
    ], sprints: [
      _sprint('s1', 'a',
          startedAt: DateTime(2030, 3, 14, 9, 10),
          endedAt: DateTime(2030, 3, 14, 9, 33)),
    ]));

    expect(find.byKey(const Key('day_timeline_sprint_s1')), findsNothing);
    expect(find.textContaining('sprint'), findsNothing);
  });

  testWidgets('a Sprint on an Outcome with no tile is not drawn',
      (tester) async {
    await tester.pumpWidget(_app([
      _entry('a', 60),
    ], sprints: [
      _sprint('s1', 'other',
          startedAt: DateTime(2030, 3, 15, 9, 10),
          endedAt: DateTime(2030, 3, 15, 9, 33)),
    ]));

    expect(find.byKey(const Key('day_timeline_sprint_s1')), findsNothing);
    expect(find.textContaining('sprint'), findsNothing);
  });

  testWidgets('an Outcome that ran no Sprint counts none', (tester) async {
    await tester.pumpWidget(_app([_entry('a', 60)]));

    expect(find.byKey(const Key('day_timeline_sprint_lane')), findsOneWidget);
    expect(find.textContaining('sprint'), findsNothing);
  });

  testWidgets('a split Outcome counts its Sprints once', (tester) async {
    // The set time leaves two 30-minute gaps; 50 minutes fits neither whole.
    await tester.pumpWidget(_app([
      _entry('blocker', 60, pinned: DateTime(2030, 3, 15, 9, 30)),
      _entry('split', 50),
    ], availableMinutes: 120, sprints: [
      _sprint('s1', 'split',
          startedAt: DateTime(2030, 3, 15, 9, 10),
          endedAt: DateTime(2030, 3, 15, 9, 33)),
    ]));

    expect(find.byKey(const Key('day_timeline_tile_split_1')), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_tile_split_2')), findsOneWidget);
    expect(find.textContaining('1 sprint · 23m'), findsOneWidget);
  });
}
