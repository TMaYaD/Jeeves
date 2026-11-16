import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/search_query.dart';
import '../models/search_result.dart';
import 'database_provider.dart';
import 'synced_preferences_provider.dart';

// ---------------------------------------------------------------------------
// Query state
// ---------------------------------------------------------------------------

/// Mutable search parameters. The search screen writes to this on each
/// (debounced) keystroke and filter change.
///
/// autoDispose so state resets to [SearchQuery()] automatically whenever
/// the search screen is popped and no widget is listening.
final searchQueryProvider =
    NotifierProvider.autoDispose<SearchQueryNotifier, SearchQuery>(
        SearchQueryNotifier.new);

class SearchQueryNotifier extends Notifier<SearchQuery> {
  @override
  SearchQuery build() => const SearchQuery();

  void update(SearchQuery query) => state = query;
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// Reactive stream of search results.
///
/// Emits an empty list immediately when [searchQueryProvider] is empty (no
/// active query). Uses [StreamProvider.autoDispose] so the Drift stream is
/// cancelled when the search screen is popped.
final searchResultsProvider =
    StreamProvider.autoDispose<List<SearchResult>>((ref) {
  final query = ref.watch(searchQueryProvider);
  if (query.isEmpty) return Stream.value([]);

  final db = ref.watch(databaseProvider);

  return db.searchDao.search(query);
});

// ---------------------------------------------------------------------------
// Hidden done-match count
// ---------------------------------------------------------------------------

/// Counts completed tasks that would match the current query if Include Done
/// were enabled. Returns 0 when [includeDone] is already true or when the
/// entire query is empty — in both cases the hint is not needed.
final hiddenDoneMatchCountProvider =
    StreamProvider.autoDispose<int>((ref) {
  final query = ref.watch(searchQueryProvider);
  if (query.includeDone || query.isEmpty) return Stream.value(0);

  final db = ref.watch(databaseProvider);

  return db.searchDao.countDoneOnlyMatches(query);
});

// ---------------------------------------------------------------------------
// Recent searches
// ---------------------------------------------------------------------------

/// Synced list of the last 10 search queries (most recent first). The latest
/// whole list wins across devices.
final recentSearchesProvider =
    NotifierProvider<RecentSearchesNotifier, List<String>>(
  RecentSearchesNotifier.new,
);

class RecentSearchesNotifier extends Notifier<List<String>> {
  static const _maxCount = 10;

  /// Serialises the local read-modify-write, so two overlapping calls cannot
  /// each read the same list and overwrite one another. The next caller waits
  /// for the one before it.
  Future<void> _pendingMutation = Future<void>.value();

  @override
  List<String> build() {
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) state = _fromPrefs(next.value);
    });
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    return current != null ? _fromPrefs(current) : const [];
  }

  List<String> _fromPrefs(SyncedPreferences prefs) =>
      prefs.get<List<dynamic>>(kRecentSearchesPrefKey)?.whereType<String>().toList() ??
      const [];

  /// Waits for the loaded snapshot so an early write cannot replace the stored
  /// list with a one-entry list.
  Future<List<String>> _loaded() async =>
      _fromPrefs(await ref.read(syncedPreferencesProvider.future));

  /// Runs [mutation] after every earlier local mutation has finished.
  ///
  /// Each mutation replaces the whole list, so two of them that read the same
  /// snapshot would each drop the other's new entry. Serialising them keeps a
  /// local lost update out of the list; the cross-device last-write-wins
  /// behaviour is unchanged.
  Future<void> _mutate(Future<void> Function() mutation) async {
    final previous = _pendingMutation;
    final done = Completer<void>();
    _pendingMutation = done.future;
    try {
      await previous;
      await mutation();
    } finally {
      // Always release the queue, so a failed mutation cannot wedge it.
      done.complete();
    }
  }

  Future<void> add(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    await _mutate(() async {
      final current = await _loaded();
      final updated = [trimmed, ...current.where((s) => s != trimmed)]
          .take(_maxCount)
          .toList();
      state = updated;
      await syncedPrefs(ref).set(kRecentSearchesPrefKey, updated);
    });
  }

  Future<void> remove(String query) async {
    await _mutate(() async {
      final current = await _loaded();
      final updated = current.where((s) => s != query).toList();
      state = updated;
      await syncedPrefs(ref).set(kRecentSearchesPrefKey, updated);
    });
  }

  Future<void> clearAll() async {
    await _mutate(() async {
      await ref.read(syncedPreferencesProvider.future);
      state = const [];
      await syncedPrefs(ref).remove(kRecentSearchesPrefKey);
    });
  }
}
