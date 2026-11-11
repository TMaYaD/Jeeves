import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../widgets/active_filter_bar.dart';
import '../../widgets/async_list.dart';
import '../../widgets/outcome_row.dart';

/// Shared list screen for all GTD views (Next Actions, Waiting For, etc.).
///
/// Displays todos in a scrollable list. Tapping a todo navigates to
/// `/task/:id` for editing and state transitions.
class GtdListScreen extends ConsumerWidget {
  const GtdListScreen({
    super.key,
    required this.provider,
    this.emptyIcon = Icons.inbox_outlined,
    this.emptyTitle = 'Nothing here yet',
    this.emptySubtitle,
    this.showFilterBar = true,
  });

  final StreamProvider<List<Todo>> provider;
  final IconData? emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;

  /// Whether to render the [ActiveFilterBar]. Screens whose stream ignores
  /// the context-tag filter (Done, Trash) pass false — showing a filter bar
  /// the list doesn't apply would lie to the user.
  final bool showFilterBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(provider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showFilterBar) const ActiveFilterBar(),
            Expanded(
              child: AsyncList<Todo>(
                asyncValue: asyncItems,
                emptyIcon: emptyIcon,
                emptyTitle: emptyTitle,
                emptySubtitle: emptySubtitle,
                dataBuilder: (context, items) => ListView.builder(
                  padding: const EdgeInsets.only(top: 8, bottom: 24),
                  itemCount: items.length,
                  itemBuilder: (_, i) => OutcomeRow(
                    title: items[i].title,
                    energyLevel: items[i].energyLevel,
                    timeEstimateMinutes: items[i].timeEstimate,
                    dueDate: items[i].dueDate,
                    onTap: () => context.push('/task/${items[i].id}'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
