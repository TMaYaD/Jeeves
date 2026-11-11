import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../providers/gtd_lists_provider.dart';
import '../../widgets/active_filter_bar.dart';
import '../../widgets/async_list.dart';
import '../../widgets/outcome_row.dart';

class WaitingForScreen extends ConsumerWidget {
  const WaitingForScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncGrouped = ref.watch(waitingListGroupedProvider);
    // Flatten the map into its entries so the standard AsyncList builder can
    // own the loading / error / empty surfaces. The data builder reassembles
    // the grouped layout from the entries.
    final asyncEntries =
        asyncGrouped.whenData((grouped) => grouped.entries.toList());

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ActiveFilterBar(),
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
                            return OutcomeRow(
                              title: todo.title,
                              energyLevel: todo.energyLevel,
                              timeEstimateMinutes: todo.timeEstimate,
                              dueDate: todo.dueDate,
                              onTap: () =>
                                  context.push('/task/${todo.id}'),
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
