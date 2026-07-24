import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../providers/gtd_lists_provider.dart';
import '../../widgets/active_filter_bar.dart';
import '../../widgets/async_list.dart';

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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 20, 8),
              child: Row(
                children: [
                  Builder(
                    builder: (ctx) => IconButton(
                      icon: const Icon(Icons.menu),
                      onPressed: () {
                        ctx
                            .findRootAncestorStateOfType<ScaffoldState>()
                            ?.openDrawer();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Waiting For',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ],
              ),
            ),
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
                            return _WaitingItem(
                              todo: todo,
                              onTap: () =>
                                  context.push('/task/${todo.id}'),
                            );
                          },
                          childCount: entry.value.length,
                        ),
                      ),
                    ],
                    // 96px clears the global capture FAB (#458).
                    const SliverToBoxAdapter(child: SizedBox(height: 96)),
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

class _WaitingItem extends StatelessWidget {
  const _WaitingItem({required this.todo, required this.onTap});

  final Todo todo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                todo.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E),
                ),
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF9CA3AF)),
          ],
        ),
      ),
    );
  }
}
