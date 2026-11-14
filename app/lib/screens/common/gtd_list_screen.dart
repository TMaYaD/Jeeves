import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
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

  void _clear() => setState(() => _selectedIds = {});

  @override
  Widget build(BuildContext context) {
    final asyncItems = ref.watch(widget.provider);
    final items = asyncItems.asData?.value ?? const <Todo>[];
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
