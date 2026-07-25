import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/search_result.dart';
import '../../providers/search_provider.dart';
import '../../widgets/app_title_bar/app_title_bar.dart';
import '../../widgets/capture/capture_action.dart';
import '../../widgets/async_list.dart';
import 'widgets/recent_searches_list.dart';
import 'widgets/search_filter_bar.dart';
import 'widgets/search_result_tile.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _commitText(String text) {
    _debounce?.cancel();
    final current = ref.read(searchQueryProvider);
    ref.read(searchQueryProvider.notifier).update(current.copyWith(text: text));
  }

  void _onTextChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _commitText(text);
    });
  }

  void _onSubmit(String text) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) {
      ref.read(recentSearchesProvider.notifier).add(trimmed);
    }
  }

  void _restoreRecentSearch(String query) {
    _controller.text = query;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: query.length),
    );
    _commitText(query);
  }

  void _clearText() {
    _controller.clear();
    _commitText('');
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(searchQueryProvider);
    final resultsAsync = ref.watch(searchResultsProvider);
    final recentSearches = ref.watch(recentSearchesProvider);

    return Scaffold(
      appBar: AppTitleBar(
        title: 'Search',
        pinnedAction: captureAction(context),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _SearchBar(
              controller: _controller,
              focusNode: _focusNode,
              hasText: query.text.isNotEmpty,
              onChanged: _onTextChanged,
              onSubmitted: _onSubmit,
              onClear: _clearText,
            ),
            SearchFilterBar(query: query),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            Expanded(
              child: query.isEmpty
                  ? RecentSearchesList(
                      searches: recentSearches,
                      onTap: _restoreRecentSearch,
                      onRemove: (s) =>
                          ref.read(recentSearchesProvider.notifier).remove(s),
                      onClearAll: () =>
                          ref.read(recentSearchesProvider.notifier).clearAll(),
                    )
                  : _Results(resultsAsync: resultsAsync, queryText: query.text),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search bar
// ---------------------------------------------------------------------------

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.hasText,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool hasText;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    // The bar owns the back affordance; the query field sits flush beneath it,
    // the ADR's home for screen-specific chrome (the bar title is a String).
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: true,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search tasks…',
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor: const Color(0xFFF3F4F6),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          prefixIcon: const Icon(
            Icons.search,
            color: Color(0xFF9CA3AF),
          ),
          suffixIcon: hasText
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: onClear,
                )
              : null,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

class _Results extends ConsumerWidget {
  const _Results({
    required this.resultsAsync,
    required this.queryText,
  });

  final AsyncValue<List<SearchResult>> resultsAsync;
  final String queryText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AsyncList<SearchResult>(
      asyncValue: resultsAsync,
      emptyTitle: 'No tasks match "$queryText"',
      // The hidden-done hint is search-specific behaviour that the standard
      // empty surface can't express; route through emptyBuilder so loading /
      // error still use the shared visuals while the hint stays put.
      emptyBuilder: (context) => _SearchEmptyState(queryText: queryText),
      dataBuilder: (_, results) => ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: results.map((r) => SearchResultTile(result: r)).toList(),
      ),
    );
  }
}

class _SearchEmptyState extends ConsumerWidget {
  const _SearchEmptyState({required this.queryText});

  final String queryText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hiddenCountAsync = ref.watch(hiddenDoneMatchCountProvider);
    final hiddenCount = hiddenCountAsync.maybeWhen(
      data: (v) => v,
      orElse: () => 0,
    );

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off, size: 48, color: Color(0xFFD1D5DB)),
          const SizedBox(height: 12),
          Text(
            'No tasks match "$queryText"',
            style: const TextStyle(color: Color(0xFF6B7280)),
            textAlign: TextAlign.center,
          ),
          if (hiddenCount > 0) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => ref.read(searchQueryProvider.notifier).update(
                    ref
                        .read(searchQueryProvider)
                        .copyWith(includeDone: true),
                  ),
              child: Text(
                '$hiddenCount ${hiddenCount == 1 ? 'match' : 'matches'} in completed tasks.',
                style: const TextStyle(
                  color: Color(0xFF3B82F6),
                  fontSize: 13,
                  decoration: TextDecoration.underline,
                  decorationColor: Color(0xFF3B82F6),
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
