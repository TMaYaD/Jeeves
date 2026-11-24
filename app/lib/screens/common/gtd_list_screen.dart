import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../providers/place_gate_provider.dart';
import '../../widgets/active_filter_bar.dart';
import '../../widgets/async_list.dart';
import '../../widgets/outcome_multi_select.dart';

/// Shared list screen for all GTD views (Next, Someday/Maybe, Project, etc.).
///
/// Displays todos in a scrollable list. Tapping a todo navigates to
/// `/task/:id` for editing and state transitions. Where [selectable], a
/// long-press enters multi-select for bulk Project, Tag and status changes.
class GtdListScreen extends ConsumerStatefulWidget {
  const GtdListScreen({
    super.key,
    required this.provider,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyTitle = 'Nothing here yet',
    this.emptySubtitle,
    this.showFilterBar = true,
    this.selectable = true,
    this.showPlaceName = false,
    this.header,
  });

  final StreamProvider<List<Todo>> provider;
  final IconData? emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;

  /// Whether to render the [ActiveFilterBar]. Screens whose stream ignores
  /// the context-tag filter (Done, Trash) pass false — showing a filter bar
  /// the list doesn't apply would lie to the user.
  final bool showFilterBar;

  /// Whether long-press enters multi-select. Done and Trash are read-oriented
  /// record surfaces and pass false.
  final bool selectable;

  /// Whether each row names the Place its Outcome is at (issue #55). Only the
  /// Next list does: the other lists are unchanged by a Place.
  final bool showPlaceName;

  /// A line above the list — the Next list's calm note about not knowing
  /// where the user is (issue #55).
  final Widget? header;

  @override
  ConsumerState<GtdListScreen> createState() => _GtdListScreenState();
}

class _GtdListScreenState extends ConsumerState<GtdListScreen> {
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
    final asyncItems = ref.watch(widget.provider);
    // The retained value, not the resolved one: a list that is reloading —
    // because the location changed, say — still holds the rows it had, and
    // the selection must survive that window.
    final items = asyncItems.value ?? const <Todo>[];
    // The Place names are only read where the rows show them.
    final placeNames = widget.showPlaceName
        ? ref.watch(currentPlaceNamesProvider)
        : const <String, String>{};
    final visibleIds = {for (final t in items) t.id};
    // An Outcome that left the list (status change, filter, sync delete) drops
    // out of the selection; an empty selection is "not in the mode".
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
              if (widget.showFilterBar) const ActiveFilterBar(),
              if (selectionActive)
                OutcomeSelectionBar(
                  selectedIds: _selectedIds,
                  allIds: visibleIds,
                  onClear: _clear,
                  onSelectAll: () => setState(() => _selectedIds = visibleIds),
                ),
              if (widget.header != null) widget.header!,
              Expanded(
                child: AsyncList<Todo>(
                  asyncValue: asyncItems,
                  emptyIcon: widget.emptyIcon,
                  emptyTitle: widget.emptyTitle,
                  emptySubtitle: widget.emptySubtitle,
                  dataBuilder: (context, items) => ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 24),
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final todo = items[i];
                      return selectableOutcomeRow(
                        todo: todo,
                        selectionActive: selectionActive,
                        selected: _selectedIds.contains(todo.id),
                        placeName: placeNames[todo.id],
                        onOpen: () => context.push('/task/${todo.id}'),
                        onToggle: () => _toggle(todo.id),
                        onEnterSelection:
                            widget.selectable ? () => _toggle(todo.id) : null,
                      );
                    },
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
