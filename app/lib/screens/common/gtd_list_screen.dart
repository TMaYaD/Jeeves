import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/gtd_database.dart';
import '../../providers/tag_filter_provider.dart';
import '../../providers/tags_provider.dart';

/// Shared list screen for all GTD views (Next Actions, Waiting For, etc.).
///
/// Displays todos in a scrollable list. Tapping a todo navigates to
/// `/task/:id` for editing and state transitions.
class GtdListScreen extends ConsumerWidget {
  const GtdListScreen({
    super.key,
    required this.title,
    required this.provider,
  });

  final String title;
  final StreamProvider<List<Todo>> provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(provider);

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
                        ctx.findRootAncestorStateOfType<ScaffoldState>()?.openDrawer();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ],
              ),
            ),
            const _ActiveFilterBar(),
            Expanded(
              child: asyncItems.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(child: Text('Error: $err')),
                data: (items) {
                  if (items.isEmpty) {
                    return Center(
                      child: Text(
                        'Nothing here yet',
                        style:
                            TextStyle(color: const Color(0xFF9CA3AF)),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 24),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _GtdListItem(
                      todo: items[i],
                      onTap: () => context.push('/task/${items[i].id}'),
                    ),
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

// ---------------------------------------------------------------------------
// Active filter bar
// ---------------------------------------------------------------------------

/// Horizontal strip shown below the screen header when a tag filter is active.
///
/// Displays each selected tag as a removable chip plus a "Clear all" button.
/// Renders nothing when the filter set is empty.
class _ActiveFilterBar extends ConsumerWidget {
  const _ActiveFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedIds = ref.watch(tagFilterProvider);
    if (selectedIds.isEmpty) return const SizedBox.shrink();

    final notifier = ref.read(tagFilterProvider.notifier);
    final allTags = ref.watch(contextTagsProvider).asData?.value ?? [];
    final selectedTags =
        allTags.where((t) => selectedIds.contains(t.id)).toList();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: const Color(0xFFEFF6FF),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ...selectedTags.map(
              (t) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InputChip(
                  key: Key('active_filter_chip_${t.id}'),
                  label: Text(t.name,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF1D4ED8))),
                  selected: true,
                  selectedColor: const Color(0xFFDBEAFE),
                  deleteIcon:
                      const Icon(Icons.close, size: 14, color: Color(0xFF1D4ED8)),
                  onDeleted: () => notifier.toggle(t.id),
                  onPressed: () => notifier.toggle(t.id),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            TextButton(
              key: const Key('active_filter_clear_all'),
              onPressed: notifier.clear,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Clear all',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Single list item
// ---------------------------------------------------------------------------

class _GtdListItem extends StatelessWidget {
  const _GtdListItem({required this.todo, required this.onTap});

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    todo.title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                  if (todo.energyLevel != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      _energyLabel(todo.energyLevel!),
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF9CA3AF)),
                    ),
                  ],
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF9CA3AF)),
          ],
        ),
      ),
    );
  }

  String _energyLabel(String level) => switch (level) {
        'low' => 'Low energy',
        'medium' => 'Medium energy',
        'high' => 'High energy',
        _ => level,
      };
}
