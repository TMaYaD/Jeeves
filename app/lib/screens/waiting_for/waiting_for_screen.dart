import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/gtd_lists_provider.dart';
import '../../widgets/active_filter_bar.dart';

class WaitingForScreen extends ConsumerWidget {
  const WaitingForScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncGrouped = ref.watch(waitingListGroupedProvider);

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
              child: asyncGrouped.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (err, stack) {
                  debugPrint('WaitingForScreen error: $err\n$stack');
                  return const Center(
                    child: Text(
                      'Something went wrong. Please try again.',
                      style: TextStyle(color: Color(0xFF9CA3AF)),
                    ),
                  );
                },
                data: (grouped) {
                  if (grouped.isEmpty) {
                    return const Center(
                      child: Text(
                        'Nothing here yet',
                        style: TextStyle(color: Color(0xFF9CA3AF)),
                      ),
                    );
                  }
                  final entries = grouped.entries.toList();
                  return CustomScrollView(
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
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  );
                },
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
