import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../providers/gtd_lists_provider.dart';
import '../../widgets/active_filter_bar.dart';
import '../../widgets/async_list.dart';
import '../../widgets/outcome_multi_select.dart';

class WaitingForScreen extends ConsumerStatefulWidget {
  const WaitingForScreen({super.key});

  @override
  ConsumerState<WaitingForScreen> createState() => _WaitingForScreenState();
}

class _WaitingForScreenState extends ConsumerState<WaitingForScreen> {
  // Selection is by Outcome id: an Outcome waiting on two people appears under
  // both, shows checked in both, and counts once.
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
    final asyncGrouped = ref.watch(waitingListGroupedProvider);
    final visibleIds = {
      for (final todos
          in asyncGrouped.asData?.value.values ?? const <List<Todo>>[])
        for (final t in todos) t.id,
    };
    _selectedIds = _selectedIds.intersection(visibleIds);
    final selectionActive = _selectedIds.isNotEmpty;
    // Flatten the map into its entries so the standard AsyncList builder can
    // own the loading / error / empty surfaces. The data builder reassembles
    // the grouped layout from the entries.
    final asyncEntries =
        asyncGrouped.whenData((grouped) => grouped.entries.toList());

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
            const ActiveFilterBar(),
            if (selectionActive)
              OutcomeSelectionBar(
                selectedIds: _selectedIds,
                allIds: visibleIds,
                onClear: _clear,
                onSelectAll: () => setState(() => _selectedIds = visibleIds),
              ),
            Expanded(
              child: AsyncList<MapEntry<Tag, List<Todo>>>(
                asyncValue: asyncEntries,
                emptyIcon: Icons.people_outline,
                emptyTitle: 'Nothing waiting on anyone',
                emptySubtitle:
                    'Items you delegate or are blocked on land here.',
                dataBuilder: (context, entries) => CustomScrollView(
                  slivers: [
                    for (final entry in entries) ...[
                      SliverToBoxAdapter(
                        child: _SectionHeader(name: entry.key.name),
                      ),
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (_, i) {
                            final todo = entry.value[i];
                            return selectableOutcomeRow(
                              todo: todo,
                              selectionActive: selectionActive,
                              selected: _selectedIds.contains(todo.id),
                              onOpen: () => context.push('/task/${todo.id}'),
                              onToggle: () => _toggle(todo.id),
                              onEnterSelection: () => _toggle(todo.id),
                            );
                          },
                          childCount: entry.value.length,
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
