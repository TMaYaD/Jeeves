import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/search_query.dart';
import '../../../models/todo.dart' show GtdState;
import '../../../providers/search_provider.dart';

/// Horizontal scrolling row of filter chips for structured search parameters.
class SearchFilterBar extends ConsumerWidget {
  const SearchFilterBar({super.key, required this.query});

  final SearchQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          _StateFilterChip(query: query),
          const SizedBox(width: 8),
          _EnergyFilterChip(query: query),
          const SizedBox(width: 8),
          _TimeFilterChip(query: query),
          const SizedBox(width: 8),
          _IncludeDoneChip(query: query),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// State filter
// ---------------------------------------------------------------------------

class _StateFilterChip extends ConsumerWidget {
  const _StateFilterChip({required this.query});

  final SearchQuery query;

  void _updateQuery(WidgetRef ref, SearchQuery q) =>
      ref.read(searchQueryProvider.notifier).update(q);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = query.states.isNotEmpty;
    final label = isActive
        ? (query.states.length == 1
            ? query.states.first.displayName
            : '${query.states.length} states')
        : 'All states';

    return ActionChip(
      avatar: Icon(
        Icons.filter_list,
        size: 14,
        color: isActive ? const Color(0xFF2563EB) : const Color(0xFF9CA3AF),
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: isActive ? const Color(0xFF2563EB) : const Color(0xFF374151),
        ),
      ),
      backgroundColor:
          isActive ? const Color(0xFFEFF6FF) : const Color(0xFFF9FAFB),
      side: BorderSide(
        color:
            isActive ? const Color(0xFF2563EB) : const Color(0xFFE5E7EB),
      ),
      onPressed: () => _showSheet(context, ref),
    );
  }

  void _showSheet(BuildContext context, WidgetRef ref) {
    final allStates = GtdState.values.toList();
    var selected = Set<GtdState>.from(query.states);

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Filter by State',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ...allStates.map(
                  (s) => CheckboxListTile(
                    dense: true,
                    title: Text(s.displayName),
                    value: selected.contains(s),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        selected = {...selected, s};
                      } else {
                        selected = selected.difference({s});
                      }
                    }),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          _updateQuery(
                            ref,
                            ref.read(searchQueryProvider).copyWith(
                                  states: const {},
                                ),
                          );
                          Navigator.pop(ctx);
                        },
                        child: const Text('Clear'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          _updateQuery(
                            ref,
                            ref.read(searchQueryProvider).copyWith(
                                  states: selected,
                                ),
                          );
                          Navigator.pop(ctx);
                        },
                        child: const Text('Apply'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Energy filter
// ---------------------------------------------------------------------------

class _EnergyFilterChip extends ConsumerWidget {
  const _EnergyFilterChip({required this.query});

  final SearchQuery query;

  void _updateQuery(WidgetRef ref, SearchQuery q) =>
      ref.read(searchQueryProvider.notifier).update(q);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = query.energyLevels.isNotEmpty;
    final label = isActive
        ? query.energyLevels.map(_label).join(', ')
        : 'Energy';

    return ActionChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: isActive ? const Color(0xFF2563EB) : const Color(0xFF374151),
        ),
      ),
      backgroundColor:
          isActive ? const Color(0xFFEFF6FF) : const Color(0xFFF9FAFB),
      side: BorderSide(
        color:
            isActive ? const Color(0xFF2563EB) : const Color(0xFFE5E7EB),
      ),
      onPressed: () => _showSheet(context, ref),
    );
  }

  static String _label(String level) => switch (level) {
        'low' => 'Low',
        'medium' => 'Medium',
        'high' => 'High',
        _ => level,
      };

  void _showSheet(BuildContext context, WidgetRef ref) {
    const levels = ['low', 'medium', 'high'];
    var selected = Set<String>.from(query.energyLevels);

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Filter by Energy',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ...levels.map(
                  (lvl) => CheckboxListTile(
                    dense: true,
                    title: Text(_label(lvl)),
                    value: selected.contains(lvl),
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        selected = {...selected, lvl};
                      } else {
                        selected = selected.difference({lvl});
                      }
                    }),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          _updateQuery(
                            ref,
                            ref.read(searchQueryProvider).copyWith(
                                  energyLevels: const {},
                                ),
                          );
                          Navigator.pop(ctx);
                        },
                        child: const Text('Clear'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          _updateQuery(
                            ref,
                            ref.read(searchQueryProvider).copyWith(
                                  energyLevels: selected,
                                ),
                          );
                          Navigator.pop(ctx);
                        },
                        child: const Text('Apply'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Time estimate filter
// ---------------------------------------------------------------------------

class _TimeFilterChip extends ConsumerWidget {
  const _TimeFilterChip({required this.query});

  final SearchQuery query;

  void _updateQuery(WidgetRef ref, SearchQuery q) =>
      ref.read(searchQueryProvider.notifier).update(q);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isActive = query.timeEstimateMaxMinutes != null;
    final label =
        isActive ? '≤ ${query.timeEstimateMaxMinutes} min' : 'Time';

    return ActionChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: isActive ? const Color(0xFF2563EB) : const Color(0xFF374151),
        ),
      ),
      backgroundColor:
          isActive ? const Color(0xFFEFF6FF) : const Color(0xFFF9FAFB),
      side: BorderSide(
        color:
            isActive ? const Color(0xFF2563EB) : const Color(0xFFE5E7EB),
      ),
      onPressed: () => _showSheet(context, ref),
    );
  }

  void _showSheet(BuildContext context, WidgetRef ref) {
    const options = [15, 30, 60, 90, 120];
    final current = query.timeEstimateMaxMinutes;

    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Filter by Time Estimate',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ...options.map(
                (min) => ListTile(
                  dense: true,
                  title: Text('≤ $min minutes'),
                  selected: current == min,
                  selectedColor: const Color(0xFF2563EB),
                  leading: current == min
                      ? const Icon(Icons.check,
                          size: 18, color: Color(0xFF2563EB))
                      : const SizedBox(width: 18),
                  onTap: () {
                    _updateQuery(
                      ref,
                      min == current
                          ? ref
                              .read(searchQueryProvider)
                              .copyWith(clearTimeEstimate: true)
                          : ref
                              .read(searchQueryProvider)
                              .copyWith(timeEstimateMaxMinutes: min),
                    );
                    Navigator.pop(ctx);
                  },
                ),
              ),
              if (current != null) ...[
                const Divider(),
                ListTile(
                  dense: true,
                  title: const Text('Clear filter'),
                  leading: const Icon(Icons.clear, size: 18),
                  onTap: () {
                    _updateQuery(
                      ref,
                      ref.read(searchQueryProvider).copyWith(
                            clearTimeEstimate: true,
                          ),
                    );
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Include done toggle
// ---------------------------------------------------------------------------

class _IncludeDoneChip extends ConsumerWidget {
  const _IncludeDoneChip({required this.query});

  final SearchQuery query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilterChip(
      label: const Text('Include Done', style: TextStyle(fontSize: 12)),
      selected: query.includeDone,
      selectedColor: const Color(0xFFEFF6FF),
      checkmarkColor: const Color(0xFF2563EB),
      onSelected: (v) {
        ref.read(searchQueryProvider.notifier).update(
              ref.read(searchQueryProvider).copyWith(includeDone: v),
            );
      },
    );
  }
}
