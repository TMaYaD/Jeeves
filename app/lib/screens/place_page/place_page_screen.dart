/// The place page: every Outcome with a Place, grouped by Place (issue #55).
///
/// This is where an Outcome hidden because the user is somewhere else can be
/// found. It is a list and nothing more: no map, no errands, no route.
///
/// The list follows the same multi-select convention as the other grouped
/// lists: a tap opens the Outcome, a long-press enters the mode, and the bar
/// above the list carries the bulk actions.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/place_page_provider.dart';
import '../../widgets/async_list.dart';
import '../../widgets/outcome_multi_select.dart';

/// The list of every Outcome with a Place.
class PlacePageScreen extends ConsumerStatefulWidget {
  const PlacePageScreen({super.key});

  @override
  ConsumerState<PlacePageScreen> createState() => _PlacePageScreenState();
}

class _PlacePageScreenState extends ConsumerState<PlacePageScreen> {
  /// Selection is by Outcome id: an Outcome with two Places would appear under
  /// both, show checked in both, and count once.
  Set<String> _selectedIds = {};

  void _toggle(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      final next = {..._selectedIds};
      if (!next.remove(id)) next.add(id);
      _selectedIds = next;
    });
  }

  // Also runs after an awaited bulk write; the screen may be gone by then.
  void _clear() {
    if (!mounted) return;
    setState(() => _selectedIds = {});
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(placePageGroupsProvider);
    final visibleIds = {
      for (final group in groups.value ?? const <PlacePageGroup>[])
        for (final row in group.rows)
          row.todo.id,
    };
    _selectedIds = _selectedIds.intersection(visibleIds);
    final selectionActive = _selectedIds.isNotEmpty;

    return PopScope(
      canPop: !selectionActive,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _clear();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selectionActive)
                OutcomeSelectionBar(
                  selectedIds: _selectedIds,
                  allIds: visibleIds,
                  onClear: _clear,
                  onSelectAll: () => setState(() => _selectedIds = visibleIds),
                ),
              Expanded(
                child: AsyncList<PlacePageGroup>(
                  asyncValue: groups,
                  emptyIcon: Icons.place_outlined,
                  emptyTitle: 'Nothing at a place',
                  emptySubtitle:
                      'Outcomes you give a place to are listed here.',
                  dataBuilder: (context, entries) => CustomScrollView(
                    slivers: [
                      for (final entry in entries) ...[
                        SliverToBoxAdapter(
                          child: _SectionHeader(name: entry.label),
                        ),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (_, i) {
                              final row = entry.rows[i];
                              return selectableOutcomeRow(
                                key: Key('place_page_row_${row.todo.id}'),
                                todo: row.todo,
                                selectionActive: selectionActive,
                                selected: _selectedIds.contains(row.todo.id),
                                onOpen: () =>
                                    context.push('/task/${row.todo.id}'),
                                onToggle: () => _toggle(row.todo.id),
                                onEnterSelection: () => _toggle(row.todo.id),
                                secondary: PlaceMarker(isOnNext: row.isOnNext),
                              );
                            },
                            childCount: entry.rows.length,
                          ),
                        ),
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The marker that says where a row stands: "On Next" or "Elsewhere".
///
/// The text carries the state, not the colour: the two markers differ in
/// their words and their shape.
class PlaceMarker extends StatelessWidget {
  const PlaceMarker({super.key, required this.isOnNext});

  /// Whether the Outcome is on the Next list right now.
  final bool isOnNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      key: Key(isOnNext ? 'place_marker_on_next' : 'place_marker_elsewhere'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isOnNext ? Icons.check_circle_outline : Icons.place_outlined,
          size: 14,
          color: const Color(0xFF9CA3AF),
        ),
        const SizedBox(width: 4),
        Text(
          isOnNext ? 'On Next' : 'Elsewhere',
          style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        name,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF9CA3AF),
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
