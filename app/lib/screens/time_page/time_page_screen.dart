import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/time_page_provider.dart';
import '../../widgets/active_filter_bar.dart';
import '../../widgets/async_list.dart';
import '../../widgets/outcome_multi_select.dart';

/// What Jeeves says when nothing carries a time. One of the pool is picked at
/// random, so the app does not repeat itself.
const timePageEmptyStatePool = <String>[
  'Nothing carries a time, sir.',
  'No times on the clock, sir.',
  'Nothing is waiting on the clock, sir.',
];

/// Every Outcome that carries a time, grouped by the time it carries — the
/// named windows in name order, then the one-time times.
///
/// This is where the Outcomes the clock is holding back are visible: they are
/// off Next while their time is closed, and here they are not.
class TimePageScreen extends ConsumerStatefulWidget {
  const TimePageScreen({super.key});

  @override
  ConsumerState<TimePageScreen> createState() => _TimePageScreenState();
}

class _TimePageScreenState extends ConsumerState<TimePageScreen> {
  Set<String> _selectedIds = {};

  void _toggle(String id) {
    HapticFeedback.selectionClick();
    setState(() {
      final next = {..._selectedIds};
      if (!next.remove(id)) next.add(id);
      _selectedIds = next;
    });
  }

  void _clear() {
    if (!mounted) return;
    setState(() => _selectedIds = {});
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(timePageGroupsProvider);
    final visibleIds = {
      for (final group in groups.asData?.value ?? const <TimePageGroup>[])
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
              const ActiveFilterBar(),
              if (selectionActive)
                OutcomeSelectionBar(
                  selectedIds: _selectedIds,
                  allIds: visibleIds,
                  onClear: _clear,
                  onSelectAll: () => setState(() => _selectedIds = visibleIds),
                ),
              Expanded(
                child: AsyncList<TimePageGroup>(
                  asyncValue: groups,
                  emptyIcon: Icons.schedule_outlined,
                  emptyTitle: timePageEmptyStatePool[DateTime.now()
                      .millisecondsSinceEpoch %
                      timePageEmptyStatePool.length],
                  emptySubtitle:
                      'Outcomes with a time on them land here, hidden or not.',
                  dataBuilder: (context, groups) => CustomScrollView(
                    slivers: [
                      for (final group in groups) ...[
                        SliverToBoxAdapter(
                          child: _GroupHeader(
                            title: group.title,
                            hours: group.hours,
                          ),
                        ),
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (_, i) {
                              final row = group.rows[i];
                              return selectableOutcomeRow(
                                todo: row.todo,
                                selectionActive: selectionActive,
                                selected: _selectedIds.contains(row.todo.id),
                                onOpen: () => context.push('/task/${row.todo.id}'),
                                onToggle: () => _toggle(row.todo.id),
                                onEnterSelection: () => _toggle(row.todo.id),
                                secondary: _TimeMarker(row: row),
                              );
                            },
                            childCount: group.rows.length,
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

/// The group header: the window's name, with its hours beside it, so the rows
/// under it do not repeat them.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.hours});

  final String title;
  final String? hours;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Row(
        children: [
          // A window name may be a hundred characters long, so the title
          // wraps within the header instead of pushing the hours off the
          // screen.
          Flexible(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF9CA3AF),
                letterSpacing: 0.5,
              ),
            ),
          ),
          if (hours != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                hours!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF9CA3AF),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The marker under a row's title: when the Outcome can be done, or when its
/// time opens. The glyph and the words carry it, never a colour.
class _TimeMarker extends StatelessWidget {
  const _TimeMarker({required this.row});

  final TimePageRow row;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          row.isOnNext ? Icons.check_circle_outline : Icons.schedule_outlined,
          size: 14,
          color: const Color(0xFF9CA3AF),
        ),
        const SizedBox(width: 6),
        Text(
          row.marker,
          style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
        ),
      ],
    );
  }
}
