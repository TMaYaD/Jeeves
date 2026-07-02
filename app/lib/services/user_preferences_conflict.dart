/// Per-key conflict-resolution registry for the `user_preferences` synced
/// key-value store.
///
/// This is the executable source of truth for the conflict matrix documented
/// in `docs/SYNC.md`. It answers a single question as a pure function:
///
///   given a preference [key], the local row, and the server row, which value
///   should the reconciled row hold?
///
/// ## Why a registry rather than blanket last-write-wins
///
/// Most `user_preferences` keys are scalars where the latest intent on any
/// device is the correct winner — plain last-write-wins on `updated_at`. A few
/// keys are not scalars-in-the-usual-sense: a "snooze until X" value is a
/// *floor* the user should never see regressed, so it arbitrates by the later
/// **value**, not the later write (see [ConflictStrategy.maxTimestampValue]).
/// Future list/set-shaped keys (filter selections, pinned items) would silently
/// drop concurrent additions under naive LWW, so they get a merge
/// ([ConflictStrategy.setMerge]).
///
/// The registry keeps these exceptions in one auditable place and makes the
/// default — `lww`, which is non-destructive — apply to every current and
/// future key that is not explicitly registered otherwise. New list/set keys
/// **must** be registered as [ConflictStrategy.setMerge] before use.
///
/// ## Tombstone invariant (why "server-absent → keep local" is always safe)
///
/// Deletion in this store is modelled as a *tombstone* — a present row with
/// `value = NULL` — never a physical row removal. A genuinely absent server row
/// therefore can only mean "the server has never heard of this key", i.e. the
/// local-only data-loss case. A real cross-device delete arrives as a tombstone
/// **row**, not an absence. So the rule "server-absent → keep local" cannot ever
/// swallow a legitimate delete.
library;

import 'dart:convert';

/// How two conflicting rows for the same `user_preferences` key are reconciled.
enum ConflictStrategy {
  /// Last-write-wins on `updated_at`. The default; non-destructive for scalars.
  lww,

  /// The later *value* (parsed as a timestamp) wins among two live rows, so a
  /// stale write can never regress an active snooze floor and re-fire a silenced
  /// notification. A tombstone (clear / un-snooze) is arbitrated against a live
  /// value by LWW on `updated_at` — a clear silences the snooze, but a later
  /// re-snooze survives a stale clear. Used for snooze "until" floors.
  maxTimestampValue,

  /// Union of the two JSON-list values, so concurrent additions on two devices
  /// both survive. Provisioned for future list/set-shaped keys; no such key
  /// exists today.
  setMerge,
}

/// One side of a conflict: the row as it exists locally or in the server
/// snapshot.
///
/// A `null` [PreferenceRow] means **no row exists on this side** (server-absent
/// or local-absent). A present row whose [value] is `null` is a **tombstone**
/// (a deliberate clear/delete) — semantically distinct from an absent row.
class PreferenceRow {
  const PreferenceRow({required this.value, required this.updatedAt});

  /// JSON-encoded preference value; `null` marks a tombstone.
  final String? value;

  /// Timestamp the row was last written. Drives LWW arbitration.
  final DateTime? updatedAt;

  /// A present row with a null value — a deliberate clear/delete.
  bool get isTombstone => value == null;
}

/// The reconciled outcome: the value and timestamp the row should hold after
/// arbitration. A `null` [value] is a tombstone.
class ResolvedPreference {
  const ResolvedPreference({required this.value, required this.updatedAt});

  final String? value;
  final DateTime? updatedAt;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/// Returns the [ConflictStrategy] for [key].
///
/// Any key ending in `snoozed_until` is a snooze floor and arbitrates by
/// [ConflictStrategy.maxTimestampValue]; this deliberately covers future snooze
/// keys (e.g. the Nudge `snoozed_until` migrated onto this contract in #323)
/// without a code change. Every other key defaults to [ConflictStrategy.lww].
ConflictStrategy strategyForKey(String key) {
  if (key.endsWith('snoozed_until')) return ConflictStrategy.maxTimestampValue;
  return ConflictStrategy.lww;
}

// ---------------------------------------------------------------------------
// Resolver
// ---------------------------------------------------------------------------

/// Reconciles the [local] and [server] rows for [key] into the value that
/// should be persisted. Pure and side-effect free.
///
/// Covers the three cases the conflict matrix enumerates:
///   * **local-only** (server row absent) → keep local — safe by the tombstone
///     invariant.
///   * **server-only** (local row absent) → adopt server.
///   * **both present** → arbitrate per the key's [ConflictStrategy].
ResolvedPreference resolvePreferenceConflict(
  String key, {
  required PreferenceRow? local,
  required PreferenceRow? server,
}) {
  // Neither side has a row — nothing to reconcile.
  if (local == null && server == null) {
    return const ResolvedPreference(value: null, updatedAt: null);
  }
  // Local-only: the server snapshot omits the row. Keep local. A legitimate
  // cross-device delete would arrive as a present tombstone, not an absence,
  // so this can never swallow a real delete.
  if (server == null) {
    return ResolvedPreference(value: local!.value, updatedAt: local.updatedAt);
  }
  // Server-only: adopt the server row.
  if (local == null) {
    return ResolvedPreference(value: server.value, updatedAt: server.updatedAt);
  }
  // Both present: arbitrate per the key's registered strategy.
  return resolveWithStrategy(strategyForKey(key), local: local, server: server);
}

/// Arbitrates two present rows under an explicit [strategy], independent of the
/// registry. Exposed so a future reconciliation pass (or a key that hasn't been
/// added to the registry yet) can reconcile with a known strategy directly.
ResolvedPreference resolveWithStrategy(
  ConflictStrategy strategy, {
  required PreferenceRow local,
  required PreferenceRow server,
}) {
  switch (strategy) {
    case ConflictStrategy.lww:
      return _lww(local, server);
    case ConflictStrategy.maxTimestampValue:
      return _maxTimestampValue(local, server);
    case ConflictStrategy.setMerge:
      return _setMerge(local, server);
  }
}

// ---------------------------------------------------------------------------
// Strategy implementations
// ---------------------------------------------------------------------------

ResolvedPreference _lww(PreferenceRow local, PreferenceRow server) {
  final winner = _newer(local, server);
  return ResolvedPreference(value: winner.value, updatedAt: winner.updatedAt);
}

ResolvedPreference _maxTimestampValue(
  PreferenceRow local,
  PreferenceRow server,
) {
  // Tombstone (clear/un-snooze) vs live value arbitrates by LWW on updated_at:
  // a clear silences the snooze, but a *later* re-snooze must survive a stale
  // clear (and vice versa). Among two clears, keep the newer. The non-regress
  // rule below applies only between two *live* floors.
  if (local.isTombstone || server.isTombstone) {
    return _lww(local, server);
  }
  // Both live: the later "until" value wins so an active snooze floor never
  // regresses. Fall back to LWW if either value isn't a parseable timestamp.
  final localUntil = _parseTimestampValue(local.value);
  final serverUntil = _parseTimestampValue(server.value);
  if (localUntil == null || serverUntil == null) {
    return _lww(local, server);
  }
  if (localUntil.isAfter(serverUntil)) {
    return ResolvedPreference(value: local.value, updatedAt: local.updatedAt);
  }
  if (serverUntil.isAfter(localUntil)) {
    return ResolvedPreference(value: server.value, updatedAt: server.updatedAt);
  }
  // Equal "until" floors — break the tie by LWW on updated_at so the newer
  // write's timestamp is preserved rather than always taking the server.
  return _lww(local, server);
}

ResolvedPreference _setMerge(PreferenceRow local, PreferenceRow server) {
  // A tombstone means the set was cleared. Unioning it with a live list would
  // resurrect deleted members, so tombstone-vs-live (and two tombstones)
  // arbitrate by LWW on updated_at; only two live lists are merged.
  if (local.isTombstone || server.isTombstone) {
    return _lww(local, server);
  }
  // Union both live list values so concurrent additions on two devices both
  // survive. Assumes scalar (comparable) elements — Set dedup and the string
  // sort below don't handle nested collections reliably, so any future setMerge
  // key must hold scalars.
  final localList = _decodeList(local.value);
  final serverList = _decodeList(server.value);
  // A malformed live value (non-list or invalid JSON) can't be merged without
  // silently dropping that side, so fall back to LWW — same posture as
  // [_maxTimestampValue] with unparseable timestamps.
  if (localList == null || serverList == null) {
    return _lww(local, server);
  }
  final merged = <dynamic>{}
    ..addAll(localList)
    ..addAll(serverList);
  // Sort for a canonical, order-independent encoding so both devices converge
  // on identical bytes rather than ping-ponging on member order.
  final ordered = merged.toList()
    ..sort((a, b) => a.toString().compareTo(b.toString()));
  return ResolvedPreference(
    value: jsonEncode(ordered),
    updatedAt: _newer(local, server).updatedAt,
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// The row with the later `updated_at`. Ties resolve to [server] so a redundant
/// local re-emit doesn't override an already-synced identical value.
PreferenceRow _newer(PreferenceRow local, PreferenceRow server) {
  final localAt = local.updatedAt ?? _epoch;
  final serverAt = server.updatedAt ?? _epoch;
  return localAt.isAfter(serverAt) ? local : server;
}

/// Decodes a JSON-encoded string value into a UTC [DateTime], or `null` if it
/// isn't a parseable ISO-8601 string.
DateTime? _parseTimestampValue(String? jsonValue) {
  if (jsonValue == null) return null;
  try {
    final decoded = jsonDecode(jsonValue);
    if (decoded is! String) return null;
    return DateTime.parse(decoded).toUtc();
  } catch (_) {
    return null;
  }
}

/// Decodes a JSON-encoded list value, or returns `null` if the value is absent,
/// not a JSON array, or not valid JSON. Callers treat `null` as "not mergeable"
/// and fall back to LWW rather than silently dropping the value.
List<dynamic>? _decodeList(String? jsonValue) {
  if (jsonValue == null) return null;
  try {
    final decoded = jsonDecode(jsonValue);
    return decoded is List ? decoded : null;
  } catch (_) {
    return null;
  }
}
