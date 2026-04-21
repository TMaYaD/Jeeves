import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/search_query.dart';
import '../models/search_result.dart';
import '../models/todo.dart' show GtdState;
import 'auth_provider.dart';
import 'database_provider.dart';

// ---------------------------------------------------------------------------
// Query state
// ---------------------------------------------------------------------------

/// Mutable search parameters. The search screen writes to this on each
/// (debounced) keystroke and filter change.
final searchQueryProvider =
    NotifierProvider<SearchQueryNotifier, SearchQuery>(SearchQueryNotifier.new);

class SearchQueryNotifier extends Notifier<SearchQuery> {
  @override
  SearchQuery build() => const SearchQuery();

  void update(SearchQuery query) => state = query;
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// Reactive stream of search results grouped by GTD state.
///
/// Emits an empty map immediately when [searchQueryProvider] is empty (no
/// active query). Uses [StreamProvider.autoDispose] so the Drift stream is
/// cancelled when the search screen is popped.
final searchResultsProvider =
    StreamProvider.autoDispose<Map<GtdState, List<SearchResult>>>((ref) {
  final query = ref.watch(searchQueryProvider);
  if (query.isEmpty) return Stream.value({});

  final db = ref.watch(databaseProvider);
  final userId = ref.watch(currentUserIdProvider);

  return db.searchDao.search(userId, query).map(_groupByState);
});

Map<GtdState, List<SearchResult>> _groupByState(List<SearchResult> results) {
  final grouped = <GtdState, List<SearchResult>>{};
  for (final r in results) {
    final state = GtdState.fromString(r.todo.state);
    grouped.putIfAbsent(state, () => []).add(r);
  }
  return grouped;
}

// ---------------------------------------------------------------------------
// Recent searches
// ---------------------------------------------------------------------------

/// Persisted list of the last 10 search queries (most recent first).
final recentSearchesProvider =
    NotifierProvider<RecentSearchesNotifier, List<String>>(
  RecentSearchesNotifier.new,
);

class RecentSearchesNotifier extends Notifier<List<String>> {
  static const _key = 'jeeves_recent_searches';
  static const _maxCount = 10;

  // Set to true as soon as a local mutation (add/remove/clearAll) writes to
  // state. This prevents the async [_load] started in [build] from clobbering
  // newer in-memory changes if SharedPreferences resolves after the user has
  // already interacted.
  bool _hasLocalMutation = false;

  @override
  List<String> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (_hasLocalMutation) return;
    state = prefs.getStringList(_key) ?? [];
  }

  Future<void> add(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final updated = [trimmed, ...state.where((s) => s != trimmed)]
        .take(_maxCount)
        .toList();
    _hasLocalMutation = true;
    state = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, updated);
  }

  Future<void> remove(String query) async {
    final updated = state.where((s) => s != query).toList();
    _hasLocalMutation = true;
    state = updated;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, updated);
  }

  Future<void> clearAll() async {
    _hasLocalMutation = true;
    state = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
