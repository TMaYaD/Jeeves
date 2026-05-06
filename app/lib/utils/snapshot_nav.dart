/// Generic snapshot+index navigation primitive shared by the one-at-a-time
/// review flows in Daily Planning (inbox clarification, task review) and
/// Evening Shutdown (unfinished tasks).
///
/// Encodes the navigation skeleton agreed in #264:
/// - Snapshot loaded once at flow start (items == null until loaded).
/// - Index points at the current item.
/// - Back / forward / skip mutate only the index — pure navigation.
///
/// Action recording, revert, and per-flow side effects are intentionally
/// **not** modelled here — those shapes diverge across flows.
library;

class SnapshotNav<T> {
  const SnapshotNav({this.items, this.index = 0});

  /// items == null means "not yet loaded".
  /// items == [] means "loaded and empty" (terminal).
  final List<T>? items;

  /// 0-based cursor into [items]. May equal [items.length] to mean
  /// "all items consumed" (terminal); never less than 0.
  final int index;

  /// Convenience empty/unloaded sentinel for state defaults.
  static const SnapshotNav<Never> unloaded = SnapshotNav<Never>();

  bool get isLoaded => items != null;
  bool get isEmpty => items?.isEmpty ?? false;

  /// True when the snapshot is loaded and the index has reached or passed
  /// the end. Use to detect "all items resolved" / terminal-state UI.
  bool get isComplete => items != null && index >= items!.length;

  int get length => items?.length ?? 0;

  /// The item at [index], or null if not loaded / past the end.
  T? get current =>
      (items != null && index >= 0 && index < items!.length) ? items![index] : null;

  /// Replace the items list and reset the index to 0. Used by load.
  SnapshotNav<T> withItems(List<T> newItems) =>
      SnapshotNav<T>(items: newItems, index: 0);

  /// Increment the index by one. No bounds check — callers guard.
  SnapshotNav<T> next() => SnapshotNav<T>(items: items, index: index + 1);

  /// Decrement the index by one, clamped at 0.
  SnapshotNav<T> previous() =>
      SnapshotNav<T>(items: items, index: index > 0 ? index - 1 : 0);

  /// General copy. `clearItems: true` resets [items] back to null
  /// (used on flow re-entry / shutdown reset).
  SnapshotNav<T> copyWith({
    List<T>? items,
    int? index,
    bool clearItems = false,
  }) =>
      SnapshotNav<T>(
        items: clearItems ? null : (items ?? this.items),
        index: clearItems ? 0 : (index ?? this.index),
      );

  @override
  bool operator ==(Object other) =>
      other is SnapshotNav<T> &&
      _listEquals(items, other.items) &&
      index == other.index;

  @override
  int get hashCode => Object.hash(
        items == null ? null : Object.hashAll(items!),
        index,
      );
}

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
