import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/autoflow.dart';
import 'package:jeeves/models/batch_suggestion.dart';
import 'package:jeeves/models/day_timeline.dart';
import 'package:jeeves/models/time_context.dart';

DateTime _at(int hour, [int minute = 0]) =>
    DateTime(2026, 11, 16, hour, minute);

const _phone = (id: 'ctx-phone', name: '@phone');
const _computer = (id: 'ctx-computer', name: '@computer');

DayTimelineEntry _entry(
  String id,
  int minutes, {
  List<({String id, String name})> contexts = const [_phone],
  bool defaultEstimate = false,
  DateTime? pinned,
  String? batchId,
  bool declined = false,
  bool done = false,
  bool engaged = false,
  TimeContext? timeContext,
}) =>
    DayTimelineEntry(
      outcomeId: id,
      title: id,
      estimateMinutes: minutes,
      isDefaultEstimate: defaultEstimate,
      contextTags: contexts,
      pinnedStartAt: pinned,
      batchId: batchId,
      isBatchSuggestionDeclined: declined,
      isDone: done,
      isEngaged: engaged || done,
      timeContext: timeContext,
    );

DayLayout _layout(List<DayTimelineEntry> entries,
        {List<BusyInterval> events = const []}) =>
    autoflow(
      flowFrom: _at(9),
      dayEnd: _at(18),
      events: events,
      entries: [
        for (final e in entries)
          PlanEntryInput(
            outcomeId: e.outcomeId,
            estimateMinutes: e.estimateMinutes,
            isDefaultEstimate: e.isDefaultEstimate,
            pinnedStartAt: e.pinnedStartAt,
          ),
      ],
      chunkUnitMinutes: 23,
    );

BatchSuggestion? _suggest(
  List<DayTimelineEntry> entries, {
  List<BusyInterval> events = const [],
  DateTime? from,
  DateTime? end,
}) =>
    nextBatchSuggestion(
      entries: entries,
      layout: _layout(entries, events: events),
      flowFrom: from ?? _at(9),
      dayEnd: end ?? _at(18),
    );

BusyInterval _busy(DateTime a, DateTime b) => BusyInterval(start: a, end: b);

void main() {
  test('two small same-context entries that fit one gap are suggested', () {
    final suggestion =
        _suggest([_entry('a', 10), _entry('b', 5)], events: [
      _busy(_at(9), _at(9, 30)),
      _busy(_at(9, 55), _at(18)),
    ]);
    expect(suggestion, isNotNull);
    expect(suggestion!.contextName, '@phone');
    expect(suggestion.gapStart, _at(9, 30));
    expect(suggestion.gapEnd, _at(9, 55));
    expect([for (final m in suggestion.members) m.outcomeId], ['a', 'b']);
    expect(suggestion.members[0].start, _at(9, 30));
    expect(suggestion.members[1].start, _at(9, 40));
    expect(suggestion.totalMinutes, 15);
  });

  test('an entry estimated above 10 minutes is never a member', () {
    expect(_suggest([_entry('a', 10), _entry('big', 11)]), isNull);
    final suggestion = _suggest([_entry('a', 10), _entry('big', 11), _entry('b', 5)]);
    expect([for (final m in suggestion!.members) m.outcomeId], ['a', 'b']);
  });

  test('entries of different contexts are never mixed', () {
    expect(
      _suggest([
        _entry('a', 5),
        _entry('b', 5, contexts: const [_computer]),
      ]),
      isNull,
    );
  });

  test('a default-counted estimate is excluded', () {
    expect(_suggest([_entry('a', 10), _entry('b', 10, defaultEstimate: true)]),
        isNull);
  });

  test('pinned, batched, declined, done, engaged and Time-context entries are '
      'excluded', () {
    final base = _entry('a', 5);
    for (final other in [
      _entry('b', 5, pinned: _at(12)),
      _entry('b', 5, batchId: 'batch-1'),
      _entry('b', 5, declined: true),
      _entry('b', 5, done: true),
      _entry('b', 5, engaged: true),
      _entry('b', 5, timeContext: TimeContext.create(days: {1, 2, 3, 4, 5})),
      _entry('b', 5, contexts: const []),
    ]) {
      expect(_suggest([base, other]), isNull, reason: other.layoutSignature);
    }
  });

  test('the earliest gap that takes two wins; a gap holding one is skipped', () {
    final suggestion = _suggest([_entry('a', 10), _entry('b', 10)], events: [
      _busy(_at(9), _at(9, 30)), // gap 9:30-9:45 holds only one
      _busy(_at(9, 45), _at(11)),
      _busy(_at(11, 30), _at(18)), // gap 11:00-11:30 takes both
    ]);
    expect(suggestion!.gapStart, _at(11));
  });

  test('a pair that fits is found behind a first entry that crowds it out', () {
    // 10 + 5 would overflow the 12-minute gap, but 5 + 5 fits. `big` takes the
    // 9:00-9:10 gap before the event, so it does not sit on the pair's gap.
    final suggestion = _suggest(
      [_entry('big', 10), _entry('a', 5), _entry('b', 5)],
      events: [_busy(_at(9, 10), _at(9, 30)), _busy(_at(9, 42), _at(18))],
    );
    expect(suggestion, isNotNull);
    expect([for (final m in suggestion!.members) m.outcomeId], ['a', 'b']);
    expect(suggestion.gapStart, _at(9, 30));
  });

  test('members go in Plan order, back to back', () {
    final suggestion =
        _suggest([_entry('c', 5), _entry('a', 10), _entry('b', 5)]);
    expect([for (final m in suggestion!.members) m.outcomeId], ['c', 'a', 'b']);
    expect(suggestion.members[1].start, _at(9, 5));
    expect(suggestion.members[2].start, _at(9, 15));
  });

  test('an entry with two contexts joins the first group only', () {
    final suggestion = _suggest([
      _entry('a', 5, contexts: const [_computer, _phone]),
      _entry('b', 5, contexts: const [_phone]),
    ]);
    // 'a' belongs to @computer (first group), which has no second candidate;
    // so @phone has only 'b' and nothing is suggested.
    expect(suggestion, isNull);
  });

  test("the members' own current tiles do not block the gap", () {
    // Autoflow puts a and b at 9:00-9:10 and 9:10-9:15; the suggestion may
    // still use that very gap.
    final suggestion = _suggest([_entry('a', 10), _entry('b', 5)]);
    expect(suggestion!.gapStart, _at(9));
  });

  test("another entry's tile does block the gap", () {
    final suggestion = _suggest([
      _entry('other', 60, contexts: const []),
      _entry('a', 10),
      _entry('b', 5),
    ]);
    expect(suggestion!.gapStart, _at(10));
  });

  test('nothing is returned when only one candidate fits', () {
    expect(
      _suggest([_entry('a', 10), _entry('b', 10)], events: [
        _busy(_at(9), _at(9, 10)),
        _busy(_at(9, 25), _at(18)),
      ]),
      isNull,
    );
  });

  test('the flow start is rounded up to five minutes', () {
    final suggestion = _suggest([_entry('a', 5), _entry('b', 5)],
        from: _at(9, 2));
    expect(suggestion!.gapStart, _at(9, 5));
  });

  test('it is deterministic for the same inputs', () {
    final entries = [_entry('a', 10), _entry('b', 5), _entry('c', 5)];
    final first = _suggest(entries)!;
    final second = _suggest(entries)!;
    expect([for (final m in first.members) m.outcomeId],
        [for (final m in second.members) m.outcomeId]);
    expect(first.gapStart, second.gapStart);
  });

  test('batchAddable lists same-context candidates that are not members', () {
    final entries = [
      _entry('a', 10),
      _entry('b', 10),
      _entry('c', 5),
      _entry('x', 5, contexts: const [_computer]),
    ];
    final suggestion = nextBatchSuggestion(
      entries: entries,
      layout: _layout(entries),
      flowFrom: _at(9),
      dayEnd: _at(9, 20),
    )!;
    expect([for (final m in suggestion.members) m.outcomeId], ['a', 'b']);
    final addable = batchAddable(entries: entries, suggestion: suggestion);
    expect([for (final e in addable) e.outcomeId], ['c']);
  });

  test('a gap holding a left-out member\'s tile is not suggested', () {
    // a (10) sits at the gap start; only b + c (6 + 6) fit the 12-min gap, but
    // accepting them would land on a's tile.
    final entries = [_entry('a', 10), _entry('b', 6), _entry('c', 6)];
    final suggestion = nextBatchSuggestion(
      entries: entries,
      layout: _layout(entries),
      flowFrom: _at(9),
      dayEnd: _at(9, 12),
    );
    expect(suggestion, isNull);
  });

  test('batchMemberStarts puts members back to back', () {
    final starts =
        batchMemberStarts(_at(14), [_entry('a', 10), _entry('b', 5)]);
    expect(starts, {'a': _at(14), 'b': _at(14, 10)});
  });
}
