import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/autoflow.dart';
import 'package:jeeves/models/time_context.dart';

// 2026-11-16 is a Monday.
final _day = DateTime(2026, 11, 16);
DateTime _at(int hour, [int minute = 0]) =>
    DateTime(2026, 11, 16, hour, minute);

BusyInterval _busy(DateTime start, DateTime end) =>
    BusyInterval(start: start, end: end);

PlanEntryInput _entry(String id, int minutes,
        {bool defaultEstimate = false,
        ({DateTime start, DateTime end})? allowed,
        bool allowedToday = true,
        DateTime? pinnedStartAt}) =>
    PlanEntryInput(
      outcomeId: id,
      estimateMinutes: minutes,
      isDefaultEstimate: defaultEstimate,
      allowedInterval: allowed,
      allowedToday: allowedToday,
      pinnedStartAt: pinnedStartAt,
    );

DayLayout _flow({
  DateTime? from,
  DateTime? end,
  List<BusyInterval> events = const [],
  required List<PlanEntryInput> entries,
  int unit = 23,
  Map<String, List<PlacedPiece>> frozen = const {},
}) =>
    autoflow(
      flowFrom: from ?? _at(9),
      dayEnd: end ?? _at(18),
      events: events,
      entries: entries,
      chunkUnitMinutes: unit,
      frozen: frozen,
    );

void main() {
  group('whole placement', () {
    test('places entries back to back in Plan order from flowFrom', () {
      final layout = _flow(entries: [_entry('a', 30), _entry('b', 45)]);
      final a = layout.entryFor('a');
      final b = layout.entryFor('b');
      expect(a.status, PlacementStatus.placed);
      expect(a.pieces.single.start, _at(9));
      expect(a.pieces.single.minutes, 30);
      expect(b.pieces.single.start, _at(9, 30));
    });

    test('skips an event and starts after it', () {
      final layout = _flow(
        events: [_busy(_at(9), _at(10))],
        entries: [_entry('a', 30)],
      );
      expect(layout.entryFor('a').pieces.single.start, _at(10));
    });

    test('a later smaller entry backfills a gap a larger one skipped', () {
      final layout = _flow(
        events: [_busy(_at(9, 30), _at(10))],
        entries: [_entry('big', 60), _entry('small', 20)],
      );
      expect(layout.entryFor('big').pieces.single.start, _at(10));
      expect(layout.entryFor('small').pieces.single.start, _at(9));
    });

    test('nothing starts before flowFrom', () {
      final layout =
          _flow(from: _at(13, 15), entries: [_entry('a', 10)]);
      expect(layout.entryFor('a').pieces.single.start, _at(13, 15));
    });

    test('an entry that exactly fills a gap fits', () {
      final layout = _flow(
        events: [_busy(_at(9, 30), _at(11))],
        entries: [_entry('a', 30)],
      );
      expect(layout.entryFor('a').pieces.single.start, _at(9));
      expect(layout.entryFor('a').status, PlacementStatus.placed);
    });
  });

  group('time context', () {
    test('placement stays inside the allowed interval', () {
      final layout = _flow(
        entries: [
          _entry('a', 30, allowed: (start: _at(14), end: _at(16))),
        ],
      );
      expect(layout.entryFor('a').pieces.single.start, _at(14));
    });

    test('an interval too short for the whole estimate is chunked inside it',
        () {
      final layout = _flow(
        entries: [
          _entry('a', 60, allowed: (start: _at(14), end: _at(14, 50))),
        ],
      );
      final a = layout.entryFor('a');
      expect(a.status, PlacementStatus.partlyPlaced);
      expect(a.pieces.single.start, _at(14));
      expect(a.pieces.single.minutes, 46);
      expect(a.unplacedMinutes, 14);
    });

    test('not allowed today is flagged unplaced with that reason', () {
      final layout = _flow(
        entries: [_entry('a', 30, allowedToday: false)],
      );
      final a = layout.entryFor('a');
      expect(a.status, PlacementStatus.unplaced);
      expect(a.reason, UnplacedReason.outsideTimeContext);
      expect(a.unplacedMinutes, 30);
      expect(a.pieces, isEmpty);
    });

    test('window already over by flowFrom is flagged unplaced', () {
      final layout = _flow(
        from: _at(15),
        entries: [
          _entry('a', 30, allowed: (start: _at(9), end: _at(12))),
        ],
      );
      expect(layout.entryFor('a').status, PlacementStatus.unplaced);
      expect(layout.entryFor('a').reason, UnplacedReason.noGap);
    });
  });

  group('chunking (plan section 8 worked examples)', () {
    test('120 min into gaps of 30 and 30 → two 23-minute pieces, 74 unplaced',
        () {
      final layout = _flow(
        from: _at(9),
        end: _at(10, 30),
        events: [_busy(_at(9, 30), _at(10))],
        entries: [_entry('a', 120)],
      );
      final a = layout.entryFor('a');
      expect(a.status, PlacementStatus.partlyPlaced);
      expect(a.pieces.map((p) => p.minutes), [23, 23]);
      expect(a.pieces.map((p) => p.start), [_at(9), _at(10)]);
      expect(a.pieces.map((p) => p.part), [1, 2]);
      expect(a.unplacedMinutes, 74);
      expect(a.reason, UnplacedReason.noGap);
    });

    test('60 min into gaps of 50 and 30 → 46 then 14 (last takes remainder)',
        () {
      final layout = _flow(
        from: _at(9),
        end: _at(10, 50),
        events: [_busy(_at(9, 50), _at(10, 20))],
        entries: [_entry('a', 60)],
      );
      final a = layout.entryFor('a');
      expect(a.status, PlacementStatus.placedInPieces);
      expect(a.pieces.map((p) => p.minutes), [46, 14]);
      expect(a.pieces.map((p) => p.start), [_at(9), _at(10, 20)]);
      expect(a.unplacedMinutes, 0);
    });

    test('a gap smaller than one unit is not used', () {
      final layout = _flow(
        from: _at(9),
        end: _at(10, 10),
        events: [_busy(_at(9, 20), _at(10))],
        entries: [_entry('a', 50)],
      );
      final a = layout.entryFor('a');
      expect(a.status, PlacementStatus.unplaced);
      expect(a.reason, UnplacedReason.noGap);
      expect(a.pieces, isEmpty);
    });

    test('chunking happens only after every whole placement', () {
      // 'huge' cannot fit whole; it must not take the gap 'small' needs.
      final layout = _flow(
        from: _at(9),
        end: _at(10),
        entries: [_entry('huge', 90), _entry('small', 30)],
      );
      expect(layout.entryFor('small').pieces.single.start, _at(9));
      final huge = layout.entryFor('huge');
      expect(huge.pieces.single.start, _at(9, 30));
      expect(huge.pieces.single.minutes, 23);
      expect(huge.unplacedMinutes, 67);
    });
  });

  group('pinned entries', () {
    test('sit at the pinned start for the whole estimate, even over an event',
        () {
      final layout = _flow(
        events: [_busy(_at(11), _at(12))],
        entries: [_entry('a', 60, pinnedStartAt: _at(11, 30))],
      );
      final a = layout.entryFor('a');
      expect(a.status, PlacementStatus.placed);
      expect(a.pieces.single.start, _at(11, 30));
      expect(a.pieces.single.minutes, 60);
      expect(a.pieces.single.isPinned, isTrue);
      expect(a.pieces.single.overlapsEvent(layout.events), isTrue);
    });

    test('ignore the Time context', () {
      final layout = _flow(entries: [
        _entry('a', 30,
            pinnedStartAt: _at(8),
            allowed: (start: _at(14), end: _at(16)),
            allowedToday: false),
      ]);
      expect(layout.entryFor('a').pieces.single.start, _at(8));
    });

    test('are obstacles for unpinned entries placed earlier in the Plan', () {
      final layout = _flow(entries: [
        _entry('first', 60),
        _entry('pinned', 60, pinnedStartAt: _at(9)),
      ]);
      expect(layout.entryFor('pinned').pieces.single.start, _at(9));
      expect(layout.entryFor('first').pieces.single.start, _at(10));
    });
  });

  group('frozen placements', () {
    test('come back unchanged and block the others', () {
      final frozenPiece = PlacedPiece(
          outcomeId: 'a', start: _at(9, 40), minutes: 30, part: 1);
      final layout = _flow(
        events: [_busy(_at(9), _at(9, 20))],
        entries: [_entry('b', 30), _entry('a', 30)],
        frozen: {
          'a': [frozenPiece]
        },
      );
      expect(layout.entryFor('a').pieces.single.start, _at(9, 40));
      expect(layout.entryFor('a').status, PlacementStatus.placed);
      expect(layout.entryFor('b').pieces.single.start, _at(10, 10));
    });

    test('frozen pieces of a partly placed entry keep their flag', () {
      final layout = _flow(
        entries: [_entry('a', 60)],
        frozen: {
          'a': [
            PlacedPiece(outcomeId: 'a', start: _at(8), minutes: 23, part: 1),
          ],
        },
      );
      final a = layout.entryFor('a');
      expect(a.status, PlacementStatus.partlyPlaced);
      expect(a.unplacedMinutes, 37);
    });
  });

  group('every entry is in the result', () {
    test('overbooked day keeps all entries, in Plan order, flagged', () {
      final entries = [
        for (var i = 0; i < 6; i++) _entry('e$i', 60),
      ];
      final layout = _flow(
        from: _at(9),
        end: _at(12),
        entries: entries,
      );
      expect(layout.entries.map((e) => e.outcomeId),
          entries.map((e) => e.outcomeId));
      expect(layout.entries.where((e) => e.status == PlacementStatus.placed),
          hasLength(3));
      expect(layout.entries.where((e) => e.status == PlacementStatus.unplaced),
          hasLength(3));
    });
  });

  group('capacity', () {
    test('planned splits real and default-counted; free excludes events', () {
      final layout = _flow(
        from: _at(9),
        end: _at(17),
        events: [
          _busy(_at(10), _at(11)),
          _busy(_at(10, 30), _at(12)), // overlaps the first
          _busy(_at(16), _at(19)), // runs past the end
        ],
        entries: [
          _entry('a', 30),
          _entry('b', 10, defaultEstimate: true),
        ],
      );
      expect(layout.capacity.plannedMinutes, 40);
      expect(layout.capacity.defaultCountedMinutes, 10);
      expect(layout.capacity.realMinutes, 30);
      // 8h window − (10:00–12:00) − (16:00–17:00) = 480 − 120 − 60
      expect(layout.capacity.freeMinutes, 300);
      expect(layout.capacity.isOverbooked, isFalse);
      expect(layout.capacity.overByMinutes, 0);
    });

    test('over by the shortfall when planned exceeds free', () {
      final layout = _flow(
        from: _at(9),
        end: _at(10),
        entries: [_entry('a', 90)],
      );
      expect(layout.capacity.isOverbooked, isTrue);
      expect(layout.capacity.overByMinutes, 30);
    });

    test('zero free time is overbooked, not a division error', () {
      final layout = _flow(
        from: _at(9),
        end: _at(10),
        events: [_busy(_at(9), _at(10))],
        entries: [_entry('a', 10)],
      );
      expect(layout.capacity.freeMinutes, 0);
      expect(layout.capacity.isOverbooked, isTrue);
    });
  });

  group('TimeContext.allowedIntervalOn', () {
    test('weekly window gives that window on a matching day', () {
      final tc = TimeContext.create(
          days: {1}, startMinute: 9 * 60, endMinute: 17 * 60)!;
      expect(tc.allowedIntervalOn(_day), (start: _at(9), end: _at(17)));
    });

    test('weekly days without a window give the whole day', () {
      final tc = TimeContext.create(days: {1})!;
      expect(tc.allowedIntervalOn(_at(13, 30)),
          (start: _day, end: DateTime(2026, 11, 17)));
    });

    test('a non-matching weekday gives null', () {
      final tc = TimeContext.create(days: {2})!;
      expect(tc.allowedIntervalOn(_day), isNull);
    });

    test('a from-date in the future gives null; today or past gives the day',
        () {
      expect(
          TimeContext.create(fromDate: DateTime(2026, 11, 17))!
              .allowedIntervalOn(_day),
          isNull);
      expect(
          TimeContext.create(fromDate: DateTime(2026, 11, 16))!
              .allowedIntervalOn(_day),
          (start: _day, end: DateTime(2026, 11, 17)));
    });

    test('from-date and weekly window combine', () {
      final tc = TimeContext.create(
          fromDate: DateTime(2026, 11, 20),
          days: {1},
          startMinute: 600,
          endMinute: 660)!;
      expect(tc.allowedIntervalOn(_day), isNull);
      expect(tc.allowedIntervalOn(DateTime(2026, 11, 23)),
          (start: DateTime(2026, 11, 23, 10), end: DateTime(2026, 11, 23, 11)));
    });

    test('a window ending at 24:00 ends at the next midnight', () {
      final tc = TimeContext.create(
          days: {1}, startMinute: 23 * 60, endMinute: 24 * 60)!;
      expect(tc.allowedIntervalOn(_day),
          (start: _at(23), end: DateTime(2026, 11, 17)));
    });
  });

  group('property: no unpinned piece overlaps an event or another piece', () {
    for (var seed = 0; seed < 200; seed++) {
      test('seed $seed', () {
        final random = Random(seed);
        final from = _at(6 + random.nextInt(6), random.nextInt(4) * 15);
        final end = _at(15 + random.nextInt(8));
        final unit = 10 + random.nextInt(40);

        final events = <BusyInterval>[];
        for (var i = 0; i < random.nextInt(8); i++) {
          final s = _at(6, 0).add(Duration(minutes: random.nextInt(17 * 60)));
          events.add(_busy(s, s.add(Duration(minutes: 5 + random.nextInt(150)))));
        }

        final entries = <PlanEntryInput>[];
        for (var i = 0; i < 1 + random.nextInt(10); i++) {
          final kind = random.nextInt(5);
          ({DateTime start, DateTime end})? allowed;
          if (kind == 0) {
            final s = _at(6 + random.nextInt(14));
            allowed = (
              start: s,
              end: s.add(Duration(minutes: 15 + random.nextInt(240)))
            );
          }
          entries.add(_entry(
            'e$i',
            5 + random.nextInt(200),
            allowed: allowed,
            allowedToday: kind != 1,
            pinnedStartAt:
                kind == 2 ? _at(6).add(Duration(minutes: random.nextInt(900))) : null,
          ));
        }

        final layout = autoflow(
          flowFrom: from,
          dayEnd: end,
          events: events,
          entries: entries,
          chunkUnitMinutes: unit,
        );

        expect(layout.entries.map((e) => e.outcomeId),
            entries.map((e) => e.outcomeId),
            reason: 'every entry, in Plan order');

        final unpinned = <PlacedPiece>[];
        for (final result in layout.entries) {
          final input = entries.firstWhere((e) => e.outcomeId == result.outcomeId);
          final placed = result.pieces.fold<int>(0, (s, p) => s + p.minutes);
          expect(placed + result.unplacedMinutes, input.estimateMinutes,
              reason: '${result.outcomeId}: nothing dropped');
          expect(result.status == PlacementStatus.unplaced,
              result.pieces.isEmpty);
          for (final piece in result.pieces) {
            if (piece.isPinned) continue;
            unpinned.add(piece);
            expect(piece.start.isBefore(from), isFalse,
                reason: 'not before flowFrom');
            expect(piece.end.isAfter(end), isFalse, reason: 'not after day end');
            expect(piece.overlapsEvent(layout.events), isFalse,
                reason: '${piece.outcomeId} overlaps an event');
            if (input.allowedInterval != null) {
              expect(piece.start.isBefore(input.allowedInterval!.start), isFalse);
              expect(piece.end.isAfter(input.allowedInterval!.end), isFalse);
            }
            if (result.pieces.length > 1 && piece != result.pieces.last) {
              expect(piece.minutes % unit, 0,
                  reason: 'all but the last piece are whole units');
            }
          }
          expect(
              result.pieces.map((p) => p.part), [for (var i = 1; i <= result.pieces.length; i++) i]);
        }
        final all = layout.entries.expand((e) => e.pieces).toList();
        for (var i = 0; i < all.length; i++) {
          for (var j = i + 1; j < all.length; j++) {
            if (all[i].isPinned && all[j].isPinned) continue;
            final overlap = all[i].start.isBefore(all[j].end) &&
                all[j].start.isBefore(all[i].end);
            expect(overlap, isFalse,
                reason: '${all[i].outcomeId} and ${all[j].outcomeId} overlap');
          }
        }
      });
    }
  });
}
