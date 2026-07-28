/// Per-field merge strategies — ADR-0011's Conflict Strategy registry riding on
/// the op-log merge, and the lattice requirement that makes that safe.
///
/// A strategy is a **join-semilattice on (value, clock) pairs**: commutative,
/// associative, idempotent. That is not decoration — reduction must be
/// order-independent in both directions, and #555's compaction leans on the
/// same property. ADR-0030 records the requirement.
///
/// Three strategies exist:
///
/// * [lww] — the default, byte-for-byte today's behaviour: a field applies iff
///   its HLC is strictly greater than the stored one.
/// * [maxTimestampValue] — the snooze floor. The join is element-wise over the
///   pair: the **value join is a total order on the value alone**, and the
///   clock joins independently as `max` under HLC order.
/// * [setMerge] — sorted-unique union of two JSON arrays, clock `max`.
///   Provisioned; no production key registers it yet.
library;

import 'dart:convert';

import '../services/user_preferences_conflict.dart'
    show ConflictStrategy, strategyForKey;
import 'collection_codecs.dart' show userPreferencesCollection;
import 'hlc.dart';

/// What a strategy decides for one field.
class MergeDecision {
  const MergeDecision.skip()
      : apply = false,
        value = null,
        clock = null;

  const MergeDecision.apply(this.value, this.clock) : apply = true;

  /// False when the stored (value, clock) already is the join.
  final bool apply;
  final Object? value;
  final Hlc? clock;
}

/// The join of an incoming write with what is already stored.
abstract interface class FieldMergeStrategy {
  /// [storedValue] / [storedClock] are null when the field has never been
  /// written; every strategy must then take the incoming write.
  MergeDecision merge({
    required Object? incomingValue,
    required Hlc incomingClock,
    required Object? storedValue,
    required Hlc? storedClock,
  });
}

/// Last-write-wins on the HLC. Exactly the pre-#550 code path.
class LwwMergeStrategy implements FieldMergeStrategy {
  const LwwMergeStrategy();

  @override
  MergeDecision merge({
    required Object? incomingValue,
    required Hlc incomingClock,
    required Object? storedValue,
    required Hlc? storedClock,
  }) {
    if (storedClock != null && !(incomingClock > storedClock)) {
      return const MergeDecision.skip();
    }
    return MergeDecision.apply(incomingValue, incomingClock);
  }
}

/// The snooze floor: the value join is a **total order on the value alone**.
///
/// Sort key `(parseable?, parsed instant, canonical value bytes)`, winner =
/// max. Any parseable timestamp beats any unparseable value; among parseable,
/// the later instant wins; ties on the instant — and the all-unparseable case —
/// fall to the greater canonical JSON encoding, byte-wise. **No clock
/// participates in choosing the value, and there is no LWW fallback**: the
/// fallback was non-associative, and a clock-based tie-break broke the lattice.
///
/// The stored clock joins independently as `max(incoming, stored)` under HLC
/// order, whichever value won, so tombstone visibility keeps arbitrating by
/// plain HLC: a stale-but-later-valued write can never regress an active floor,
/// a newer clear still silences it, and a later re-snooze revives it.
///
/// **Owned divergence from ADR-0011's pairwise matrix.** Because the value join
/// is a max over *every value ever asserted*, a clear followed by an
/// earlier-valued re-snooze revives the field at the pre-clear floor rather
/// than the smaller re-snoozed value — the floor can never shrink through a
/// clear. Deliberate: it errs toward longer silence and never re-fires early.
/// Vector-pinned; recorded in ADR-0030.
class MaxTimestampValueMergeStrategy implements FieldMergeStrategy {
  const MaxTimestampValueMergeStrategy();

  @override
  MergeDecision merge({
    required Object? incomingValue,
    required Hlc incomingClock,
    required Object? storedValue,
    required Hlc? storedClock,
  }) {
    if (storedClock == null) {
      return MergeDecision.apply(incomingValue, incomingClock);
    }
    final clock = incomingClock > storedClock ? incomingClock : storedClock;
    final value = _greater(incomingValue, storedValue);
    final unchanged = clock == storedClock &&
        jsonEncode(value) == jsonEncode(storedValue);
    if (unchanged) return const MergeDecision.skip();
    return MergeDecision.apply(value, clock);
  }

  static Object? _greater(Object? a, Object? b) =>
      _compareValues(a, b) >= 0 ? a : b;

  /// The total order. Never returns 0 for values with different encodings.
  static int _compareValues(Object? a, Object? b) {
    final instantA = parseFloor(a);
    final instantB = parseFloor(b);
    if ((instantA == null) != (instantB == null)) {
      return instantA == null ? -1 : 1;
    }
    if (instantA != null && instantB != null) {
      final byInstant = instantA.compareTo(instantB);
      if (byInstant != 0) return byInstant;
    }
    return jsonEncode(a).compareTo(jsonEncode(b));
  }

  /// Microseconds since epoch for a value that reads as an ISO-8601 instant.
  ///
  /// `user_preferences` values are JSON-encoded strings, so the common shape is
  /// a string holding a quoted timestamp; a bare ISO string is accepted too.
  static int? parseFloor(Object? value) {
    if (value is! String) return null;
    String candidate = value;
    try {
      final decoded = jsonDecode(value);
      if (decoded is String) candidate = decoded;
    } on FormatException {
      // Not JSON — fall through and try the raw string.
    }
    return DateTime.tryParse(candidate)?.toUtc().microsecondsSinceEpoch;
  }
}

/// Sorted-unique union of two JSON arrays; clock `max`.
///
/// The sort is by canonical JSON encoding, which is what makes the merged value
/// byte-identical on every device rather than order-dependent.
///
/// **Every array-shaped value the strategy stores is canonical** — sorted-unique
/// in the shape it arrived in — including the first write into an empty field,
/// which has nothing to union with. Storing a caller's array raw there would
/// break ADR-0030(a)'s idempotence law: re-asserting the identical op would then
/// union the raw value into sorted form and change the reduced bytes, and #555's
/// compaction re-assertions are exactly that re-assertion.
class SetMergeStrategy implements FieldMergeStrategy {
  const SetMergeStrategy();

  @override
  MergeDecision merge({
    required Object? incomingValue,
    required Hlc incomingClock,
    required Object? storedValue,
    required Hlc? storedClock,
  }) {
    if (storedClock == null) {
      return MergeDecision.apply(canonicalize(incomingValue), incomingClock);
    }
    final clock = incomingClock > storedClock ? incomingClock : storedClock;
    final merged = _union(incomingValue, storedValue);
    final unchanged =
        clock == storedClock && jsonEncode(merged) == jsonEncode(storedValue);
    if (unchanged) return const MergeDecision.skip();
    return MergeDecision.apply(merged, clock);
  }

  /// Union of two array-shaped values. A non-array member contributes nothing
  /// but never destroys the other side; two non-arrays fall back to the
  /// [MaxTimestampValueMergeStrategy]-style byte order, which keeps the join
  /// total (and therefore associative) even on malformed input.
  ///
  /// Whenever an array-shaped value survives it survives *canonicalised*, even
  /// when only one side was an array and there was nothing to union — otherwise
  /// the same unsorted value could reach the store unchanged and re-asserting it
  /// would move it.
  static Object? _union(Object? a, Object? b) {
    final listA = _asList(a);
    final listB = _asList(b);
    if (listA == null && listB == null) {
      return jsonEncode(a).compareTo(jsonEncode(b)) >= 0 ? a : b;
    }
    if (listA == null) return _sortedUnique(listB!, asEncodedString: b is String);
    if (listB == null) return _sortedUnique(listA, asEncodedString: a is String);
    return _sortedUnique(
      [...listA, ...listB],
      asEncodedString: a is String || b is String,
    );
  }

  /// The canonical form of one value: sorted-unique when it is array-shaped,
  /// unchanged when it is not. The single definition both the first write and
  /// [_union] go through, so they cannot disagree about what "canonical" means.
  static Object? canonicalize(Object? value) {
    final list = _asList(value);
    if (list == null) return value;
    return _sortedUnique(list, asEncodedString: value is String);
  }

  /// Elements deduplicated and ordered by canonical JSON encoding.
  ///
  /// The result keeps the *shape* the value arrived in: `user_preferences.value`
  /// holds a JSON-encoded string, so a set of encoded arrays reduces to an
  /// encoded array, not a bare list.
  static Object? _sortedUnique(
    List<Object?> elements, {
    required bool asEncodedString,
  }) {
    final byEncoding = <String, Object?>{};
    for (final element in elements) {
      byEncoding[jsonEncode(element)] = element;
    }
    final keys = byEncoding.keys.toList()..sort();
    final merged = [for (final key in keys) byEncoding[key]];
    return asEncodedString ? jsonEncode(merged) : merged;
  }

  static List<Object?>? _asList(Object? value) {
    if (value is List) return value;
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is List) return decoded;
      } on FormatException {
        return null;
      }
    }
    return null;
  }
}

const FieldMergeStrategy lww = LwwMergeStrategy();
const FieldMergeStrategy maxTimestampValue = MaxTimestampValueMergeStrategy();
const FieldMergeStrategy setMerge = SetMergeStrategy();

/// The `user_preferences` field the registry arbitrates. Every other field of
/// the collection — `key`, `user_id`, `updated_at` — stays plain LWW.
const String preferenceValueField = 'value';

/// Maps ADR-0011's registry verdict onto the reducer's strategies.
///
/// `app/lib/services/user_preferences_conflict.dart` stays the executable
/// source of truth for *which key gets which strategy*; this is the adapter, so
/// a future key registers once.
FieldMergeStrategy strategyForPreferenceKey(String key) =>
    switch (strategyForKey(key)) {
      ConflictStrategy.lww => lww,
      ConflictStrategy.maxTimestampValue => maxTimestampValue,
      ConflictStrategy.setMerge => setMerge,
    };

/// Which strategy governs `(collection, field)`.
///
/// Eleven of the twelve collections are plain LWW. `user_preferences` selects
/// per entity by its `key` field — from the op's own fields when it carries one
/// (`set()` always sends `key`), else from the stored reduced `key`; an
/// unresolvable key falls back to LWW.
class MergeStrategyRegistry {
  const MergeStrategyRegistry({
    this.preferenceKeyOverrides = const <String, FieldMergeStrategy>{},
  });

  /// Preference keys whose strategy is fixed here rather than read from
  /// ADR-0011's registry. Empty in production; the golden-vector runner uses it
  /// to pin [setMerge], which is provisioned but has no production key yet.
  final Map<String, FieldMergeStrategy> preferenceKeyOverrides;

  FieldMergeStrategy resolve({
    required String collection,
    required String field,
    String? preferenceKey,
  }) {
    if (collection != userPreferencesCollection) return lww;
    if (field != preferenceValueField) return lww;
    if (preferenceKey == null) return lww;
    return preferenceKeyOverrides[preferenceKey] ??
        strategyForPreferenceKey(preferenceKey);
  }
}

/// Strategy names as they appear in `spec/sync/reducer_v1_vectors.json`.
const Map<String, FieldMergeStrategy> mergeStrategiesByName = {
  'lww': lww,
  'max_timestamp_value': maxTimestampValue,
  'set_merge': setMerge,
};
