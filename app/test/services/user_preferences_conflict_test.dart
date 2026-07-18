import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/clarify_mode.dart';
import 'package:jeeves/services/user_preferences_conflict.dart';

PreferenceRow _row(dynamic value, String updatedAt) => PreferenceRow(
      value: value == null ? null : jsonEncode(value),
      updatedAt: DateTime.parse(updatedAt),
    );

PreferenceRow _tombstone(String updatedAt) => _row(null, updatedAt);

void main() {
  group('strategyForKey', () {
    test('defaults to lww for scalar keys', () {
      expect(strategyForKey('focus_settings_sprint_duration_minutes'),
          ConflictStrategy.lww);
      expect(strategyForKey('periodic_review_last_completed_at'),
          ConflictStrategy.lww);
      expect(strategyForKey('planning_banner_dismissed_date'),
          ConflictStrategy.lww);
      expect(strategyForKey('an_unregistered_future_key'), ConflictStrategy.lww);
    });

    test('classifies every *snoozed_until key as maxTimestampValue', () {
      for (final key in [
        'planning_notification_snoozed_until',
        'shutdown_notification_snoozed_until',
        'periodic_review_notification_snoozed_until',
        // Future Nudge key migrated onto this contract (#323) — no code change.
        'snoozed_until',
        'nudge_review_snoozed_until',
      ]) {
        expect(strategyForKey(key), ConflictStrategy.maxTimestampValue,
            reason: '$key should be a snooze floor');
      }
    });

    test('clarify_mode is registered explicitly, not left to the default', () {
      // The lookup below would return lww either way, so assert against the
      // registry itself — the point of the entry is that the strategy was
      // chosen for this key rather than inherited (ADR-0011, issue #433).
      expect(preferenceConflictRegistry, contains(kClarifyModePrefKey),
          reason: 'clarify_mode must have an explicit registry entry');
      expect(preferenceConflictRegistry[kClarifyModePrefKey],
          ConflictStrategy.lww);
      expect(strategyForKey(kClarifyModePrefKey), ConflictStrategy.lww);
    });

    test('every registry entry resolves to its registered strategy', () {
      // No current entry ends in `snoozed_until`, so this does not exercise
      // precedence over the suffix rule — it pins that an exact-match entry is
      // honoured, and covers future entries as they are added.
      for (final entry in preferenceConflictRegistry.entries) {
        expect(strategyForKey(entry.key), entry.value,
            reason: '${entry.key} should resolve to its registered strategy');
      }
    });
  });

  group('three-case coverage (applies to every key)', () {
    test('local-only: server-absent row keeps local value', () {
      final r = resolvePreferenceConflict(
        'any_key',
        local: _row('local', '2026-01-01T00:00:00Z'),
        server: null,
      );
      expect(r.value, jsonEncode('local'));
    });

    test('local-only survives even for a maxTimestampValue key', () {
      final r = resolvePreferenceConflict(
        'planning_notification_snoozed_until',
        local: _row('2026-01-02T00:00:00Z', '2026-01-02T00:00:00Z'),
        server: null,
      );
      expect(r.value, jsonEncode('2026-01-02T00:00:00Z'));
    });

    test('server-only: absent local row adopts server value', () {
      final r = resolvePreferenceConflict(
        'any_key',
        local: null,
        server: _row('server', '2026-01-01T00:00:00Z'),
      );
      expect(r.value, jsonEncode('server'));
    });

    test('neither side present resolves to a tombstone', () {
      final r = resolvePreferenceConflict('any_key', local: null, server: null);
      expect(r.value, isNull);
      expect(r.updatedAt, isNull);
    });

    test('one-sided resolution keeps a list value intact (no merge)', () {
      // The one-sided cases short-circuit before strategy dispatch, so a
      // would-be setMerge list value is kept verbatim rather than unioned.
      final localOnly = resolvePreferenceConflict(
        'any_key',
        local: _row(['a', 'b'], '2026-01-01T00:00:00Z'),
        server: null,
      );
      expect((jsonDecode(localOnly.value!) as List).cast<String>(), ['a', 'b']);

      final serverOnly = resolvePreferenceConflict(
        'any_key',
        local: null,
        server: _row(['x', 'y'], '2026-01-01T00:00:00Z'),
      );
      expect((jsonDecode(serverOnly.value!) as List).cast<String>(), ['x', 'y']);
    });
  });

  group('lww strategy (both present)', () {
    test('newer updated_at wins', () {
      final r = resolvePreferenceConflict(
        'focus_settings_sprint_duration_minutes',
        local: _row(25, '2026-01-02T00:00:00Z'),
        server: _row(20, '2026-01-01T00:00:00Z'),
      );
      expect(r.value, jsonEncode(25));
      expect(r.updatedAt, DateTime.parse('2026-01-02T00:00:00Z'),
          reason: 'the winner carries its own updated_at');

      final r2 = resolvePreferenceConflict(
        'focus_settings_sprint_duration_minutes',
        local: _row(25, '2026-01-01T00:00:00Z'),
        server: _row(20, '2026-01-03T00:00:00Z'),
      );
      expect(r2.value, jsonEncode(20));
      expect(r2.updatedAt, DateTime.parse('2026-01-03T00:00:00Z'));
    });

    test('a cross-device tombstone with a newer timestamp wins', () {
      final r = resolvePreferenceConflict(
        'planning_banner_dismissed_date',
        local: _row('2026-01-01', '2026-01-01T00:00:00Z'),
        server: _tombstone('2026-01-02T00:00:00Z'),
      );
      expect(r.value, isNull);
      expect(r.updatedAt, DateTime.parse('2026-01-02T00:00:00Z'));
    });

    test('tie resolves to server (stable)', () {
      final r = resolvePreferenceConflict(
        'focus_settings_sprint_duration_minutes',
        local: _row(25, '2026-01-01T00:00:00Z'),
        server: _row(20, '2026-01-01T00:00:00Z'),
      );
      expect(r.value, jsonEncode(20));
      expect(r.updatedAt, DateTime.parse('2026-01-01T00:00:00Z'));
    });
  });

  group('maxTimestampValue strategy (snooze floors)', () {
    const key = 'periodic_review_notification_snoozed_until';

    test('later snooze value wins even when carried by an older write', () {
      // Local carries a snooze further into the future but was written earlier;
      // plain LWW would regress the floor. maxTimestampValue keeps the later
      // "until".
      final r = resolvePreferenceConflict(
        key,
        local: _row('2026-01-10T00:00:00Z', '2026-01-01T00:00:00Z'),
        server: _row('2026-01-05T00:00:00Z', '2026-01-02T00:00:00Z'),
      );
      expect(r.value, jsonEncode('2026-01-10T00:00:00Z'),
          reason: 'a later snooze floor must never regress');
      expect(r.updatedAt, DateTime.parse('2026-01-01T00:00:00Z'),
          reason: 'the winning row carries its own updated_at, not the max');
    });

    test('server later "until" wins when it is the later floor', () {
      final r = resolvePreferenceConflict(
        key,
        local: _row('2026-01-05T00:00:00Z', '2026-01-03T00:00:00Z'),
        server: _row('2026-01-10T00:00:00Z', '2026-01-01T00:00:00Z'),
      );
      expect(r.value, jsonEncode('2026-01-10T00:00:00Z'));
      expect(r.updatedAt, DateTime.parse('2026-01-01T00:00:00Z'));
    });

    test('equal "until" floors break the tie by newer updated_at', () {
      final r = resolvePreferenceConflict(
        key,
        local: _row('2026-01-10T00:00:00Z', '2026-01-04T00:00:00Z'),
        server: _row('2026-01-10T00:00:00Z', '2026-01-02T00:00:00Z'),
      );
      expect(r.value, jsonEncode('2026-01-10T00:00:00Z'));
      expect(r.updatedAt, DateTime.parse('2026-01-04T00:00:00Z'),
          reason: 'the newer write wins the tie, preserving its timestamp');
    });

    test('a newer clear (tombstone) wins over a live snooze floor', () {
      // The clear is the most recent action, so the un-snooze takes effect.
      final r = resolvePreferenceConflict(
        key,
        local: _tombstone('2026-01-06T00:00:00Z'),
        server: _row('2026-01-10T00:00:00Z', '2026-01-05T00:00:00Z'),
      );
      expect(r.value, isNull);
      expect(r.updatedAt, DateTime.parse('2026-01-06T00:00:00Z'));
    });

    test('a stale clear does not undo a fresher re-snooze', () {
      // The clear was written before the re-snooze; the later floor survives.
      final r = resolvePreferenceConflict(
        key,
        local: _tombstone('2026-01-01T00:00:00Z'),
        server: _row('2026-01-10T00:00:00Z', '2026-01-05T00:00:00Z'),
      );
      expect(r.value, jsonEncode('2026-01-10T00:00:00Z'),
          reason: 'a re-snooze written after a clear must survive');
      expect(r.updatedAt, DateTime.parse('2026-01-05T00:00:00Z'));
    });

    test('two clears resolve to the newer tombstone', () {
      final r = resolvePreferenceConflict(
        key,
        local: _tombstone('2026-01-01T00:00:00Z'),
        server: _tombstone('2026-01-02T00:00:00Z'),
      );
      expect(r.value, isNull);
      expect(r.updatedAt, DateTime.parse('2026-01-02T00:00:00Z'));
    });
  });

  group('setMerge strategy (concurrent additions survive)', () {
    // No production key registers setMerge today, so it is exercised through
    // the strategy-explicit resolver — the same seam a future list/set key
    // (or reconciliation pass) would use.
    test('union of two device lists keeps both additions without duplicates', () {
      final r = resolveWithStrategy(
        ConflictStrategy.setMerge,
        local: _row(['a', 'b'], '2026-01-01T00:00:00Z'),
        server: _row(['b', 'c'], '2026-01-02T00:00:00Z'),
      );
      final decoded = (jsonDecode(r.value!) as List).cast<String>();
      expect(decoded.toSet(), {'a', 'b', 'c'},
          reason: 'both devices\' additions must survive');
      expect(decoded.length, 3, reason: 'the shared member is not duplicated');
    });

    test('the merged encoding is canonical regardless of device order', () {
      final ab = resolveWithStrategy(
        ConflictStrategy.setMerge,
        local: _row(['a', 'b'], '2026-01-01T00:00:00Z'),
        server: _row(['c'], '2026-01-01T00:00:00Z'),
      );
      final ba = resolveWithStrategy(
        ConflictStrategy.setMerge,
        local: _row(['c'], '2026-01-01T00:00:00Z'),
        server: _row(['b', 'a'], '2026-01-01T00:00:00Z'),
      );
      expect(ab.value, ba.value,
          reason: 'both devices must converge on identical bytes');
    });

    test('an older clear does not survive a newer live list (LWW)', () {
      final r = resolveWithStrategy(
        ConflictStrategy.setMerge,
        local: _tombstone('2026-01-01T00:00:00Z'),
        server: _row(['x'], '2026-01-02T00:00:00Z'),
      );
      final decoded = (jsonDecode(r.value!) as List).cast<String>();
      expect(decoded, ['x'], reason: 'the newer live list wins');
    });

    test('a newer clear is not resurrected by an older live list', () {
      // A tombstone must not be unioned back into a live set — the clear wins
      // when it is the more recent write.
      final r = resolveWithStrategy(
        ConflictStrategy.setMerge,
        local: _tombstone('2026-01-03T00:00:00Z'),
        server: _row(['x'], '2026-01-02T00:00:00Z'),
      );
      expect(r.value, isNull,
          reason: 'a newer clear must not resurrect deleted members');
    });

    test('two tombstones resolve to the newer clear', () {
      final r = resolveWithStrategy(
        ConflictStrategy.setMerge,
        local: _tombstone('2026-01-01T00:00:00Z'),
        server: _tombstone('2026-01-02T00:00:00Z'),
      );
      expect(r.value, isNull);
      expect(r.updatedAt, DateTime.parse('2026-01-02T00:00:00Z'));
    });

    test('a malformed live value falls back to LWW instead of dropping a side',
        () {
      // `_row('oops', ...)` encodes to the non-list JSON value "oops". Merging
      // it as an empty set would silently discard that side; LWW keeps the
      // newer value verbatim.
      final r = resolveWithStrategy(
        ConflictStrategy.setMerge,
        local: _row(['a', 'b'], '2026-01-01T00:00:00Z'),
        server: _row('oops', '2026-01-02T00:00:00Z'),
      );
      expect(r.value, jsonEncode('oops'),
          reason: 'the newer (malformed) value wins under LWW, not an empty '
              'merge that drops it');
      expect(r.updatedAt, DateTime.parse('2026-01-02T00:00:00Z'));
    });
  });
}
