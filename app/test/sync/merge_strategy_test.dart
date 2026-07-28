/// The ADR-0030 lattice properties, stated as properties.
///
/// The golden vectors pin specific outcomes; this pins the *laws* those
/// outcomes rest on — commutativity, associativity and idempotence over
/// `(value, clock)` pairs. A strategy that passes every vector and fails a law
/// here is one refactor away from breaking convergence.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/services/user_preferences_conflict.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/merge_strategy.dart';

import 'harness/permutations.dart';

const _memberA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _memberB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

typedef _Write = ({Object? value, Hlc clock});

_Write _w(Object? value, int wallMs, [String member = _memberA]) =>
    (value: value, clock: Hlc(wallMs, 0, member));

/// Fold [writes] through [strategy] in order, from an empty store.
_Write? _reduce(FieldMergeStrategy strategy, List<_Write> writes) {
  _Write? stored;
  for (final write in writes) {
    final decision = strategy.merge(
      incomingValue: write.value,
      incomingClock: write.clock,
      storedValue: stored?.value,
      storedClock: stored?.clock,
    );
    if (decision.apply) stored = (value: decision.value, clock: decision.clock!);
  }
  return stored;
}

void _expectLattice(FieldMergeStrategy strategy, List<_Write> writes) {
  final orders = permutations(writes);
  final first = _reduce(strategy, orders.first)!;
  for (final order in orders) {
    final result = _reduce(strategy, order)!;
    expect(result.value, first.value, reason: 'value depends on arrival order');
    expect(result.clock, first.clock, reason: 'clock depends on arrival order');
  }
  // Idempotence: replaying the whole sequence changes nothing.
  final replayed = _reduce(strategy, [...writes, ...writes])!;
  expect(replayed.value, first.value);
  expect(replayed.clock, first.clock);
}

void main() {
  const early = '"2026-01-01T00:00:00.000Z"';
  const late = '"2026-06-01T00:00:00.000Z"';
  const compact = '"2026-01-01T00:00:00Z"';

  group('lww', () {
    test('applies strictly-greater clocks only', () {
      final reduced = _reduce(lww, [_w('a', 2000), _w('b', 1000, _memberB)])!;
      expect(reduced.value, 'a');
      expect(reduced.clock, Hlc(2000, 0, _memberA));
    });

    test('is a lattice', () {
      _expectLattice(lww, [
        _w('a', 1000),
        _w('b', 2000, _memberB),
        _w('c', 3000),
      ]);
    });
  });

  group('maxTimestampValue', () {
    test('the later floor survives a newer write carrying an earlier one', () {
      final reduced = _reduce(maxTimestampValue, [
        _w(late, 1000),
        _w(early, 2000, _memberB),
      ])!;
      expect(reduced.value, late);
      // The clock joins independently: it belongs to the losing value.
      expect(reduced.clock, Hlc(2000, 0, _memberB));
    });

    test('a parseable value outranks an unparseable one at any clock', () {
      final reduced = _reduce(maxTimestampValue, [
        _w('"not-a-time"', 9000),
        _w(early, 1000, _memberB),
      ])!;
      expect(reduced.value, early);
    });

    test('an instant tie falls to the greater canonical bytes', () {
      final reduced = _reduce(maxTimestampValue, [_w(early, 1000), _w(compact, 2000)])!;
      expect(reduced.value, compact);
    });

    test('two unparseable values order by canonical bytes', () {
      final reduced = _reduce(maxTimestampValue, [_w('"a"', 2000), _w('"z"', 1000)])!;
      expect(reduced.value, '"z"');
    });

    test('the floor never shrinks through a clear (ADR-0030 divergence)', () {
      // The clear itself is a tombstone op, arbitrated outside the field join;
      // what this pins is the field side: a later re-snooze carrying an earlier
      // value revives at the pre-clear floor.
      final reduced = _reduce(maxTimestampValue, [_w(late, 1000), _w(early, 3000)])!;
      expect(reduced.value, late);
      expect(reduced.clock, Hlc(3000, 0, _memberA));
    });

    test('is a lattice over a mixed parseable/unparseable/tied set', () {
      _expectLattice(maxTimestampValue, [
        _w(compact, 1000),
        _w(early, 2000, _memberB),
        _w('"zzz"', 3000),
      ]);
    });
  });

  group('setMerge', () {
    test('unions concurrent additions, canonically sorted', () {
      final reduced = _reduce(setMerge, [
        _w('["a","c"]', 1000),
        _w('["b","a"]', 2000, _memberB),
      ])!;
      expect(reduced.value, '["a","b","c"]');
      expect(reduced.clock, Hlc(2000, 0, _memberB));
    });

    test('keeps the encoded-string shape it arrived in', () {
      final reduced = _reduce(setMerge, [_w('["a"]', 1000), _w('["b"]', 2000)])!;
      expect(reduced.value, isA<String>());
    });

    test('canonicalises the first write into an empty field', () {
      // The first write has nothing to union with, so it is the one path that
      // could store a caller's array raw. ADR-0030(a) forbids it: see the
      // idempotence case below.
      final reduced = _reduce(setMerge, [_w('["c","a","c"]', 1000)])!;
      expect(reduced.value, '["a","c"]');
    });

    test('re-asserting an unsorted first write changes nothing', () {
      // #555's compaction re-asserts stored values under their original clocks,
      // so a re-assertion that moved the reduced bytes would make compaction
      // diverge from the log it compacts.
      final once = _reduce(setMerge, [_w('["c","a"]', 1000)])!;
      final twice = _reduce(setMerge, [_w('["c","a"]', 1000), _w('["c","a"]', 1000)])!;
      expect(twice.value, once.value);
      expect(twice.clock, once.clock);
    });

    test('is a lattice', () {
      _expectLattice(setMerge, [
        _w('["b"]', 1000),
        _w('["a","b"]', 2000, _memberB),
        _w('["c"]', 3000),
      ]);
    });

    test('is a lattice over unsorted inputs', () {
      // Every multi-write fixture above arrives pre-sorted, which is why the law
      // test used to pass over a first-write path that stored its input raw.
      //
      // A *single* unsorted write is the fixture that bites, and only through
      // the idempotence leg: with two or more distinct writes the raw first
      // write is unioned into sorted form before the reduction ends, so every
      // order still agrees and the defect hides.
      _expectLattice(setMerge, [_w('["c","a"]', 1000)]);
      _expectLattice(setMerge, [
        _w('["c","a"]', 1000),
        _w('["b","a","b"]', 2000, _memberB),
        _w('["d","c"]', 3000),
      ]);
    });

    test('canonicalises an array that displaces a non-array', () {
      // The one-sided union: nothing to merge with, and still not a licence to
      // store the array in arrival order.
      _expectLattice(setMerge, [
        _w('"not-an-array"', 1000),
        _w('["c","a"]', 2000, _memberB),
      ]);
      final reduced = _reduce(setMerge, [
        _w('"not-an-array"', 1000),
        _w('["c","a"]', 2000, _memberB),
      ])!;
      expect(reduced.value, '["a","c"]');
    });
  });

  group('registry', () {
    const registry = MergeStrategyRegistry();

    test('every collection but user_preferences is plain LWW', () {
      for (final collection in ['todos', 'actions', 'todo_tags', 'time_logs']) {
        expect(
          registry.resolve(collection: collection, field: 'anything'),
          same(lww),
        );
      }
    });

    test('only the value field of user_preferences is arbitrated', () {
      expect(
        registry.resolve(
          collection: 'user_preferences',
          field: 'key',
          preferenceKey: 'nudge_snoozed_until',
        ),
        same(lww),
      );
      expect(
        registry.resolve(
          collection: 'user_preferences',
          field: 'value',
          preferenceKey: 'nudge_snoozed_until',
        ),
        same(maxTimestampValue),
      );
    });

    test('an unresolvable key falls back to LWW', () {
      expect(
        registry.resolve(collection: 'user_preferences', field: 'value'),
        same(lww),
      );
    });

    test('ADR-0011 stays the source of truth for which key gets what', () {
      // The adapter must not fork from the registry: every enum value maps.
      for (final strategy in ConflictStrategy.values) {
        expect(
          mergeStrategiesByName.values,
          contains(switch (strategy) {
            ConflictStrategy.lww => lww,
            ConflictStrategy.maxTimestampValue => maxTimestampValue,
            ConflictStrategy.setMerge => setMerge,
          }),
        );
      }
      expect(strategyForPreferenceKey('anything_snoozed_until'),
          same(maxTimestampValue));
      expect(strategyForPreferenceKey('some_scalar'), same(lww));
    });

    test('an override wins over the registry, for keys with no strategy', () {
      const overridden = MergeStrategyRegistry(
        preferenceKeyOverrides: {'spec_set_merge': setMerge},
      );
      expect(
        overridden.resolve(
          collection: 'user_preferences',
          field: 'value',
          preferenceKey: 'spec_set_merge',
        ),
        same(setMerge),
      );
    });
  });
}
