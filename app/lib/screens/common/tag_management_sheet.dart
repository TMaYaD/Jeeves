import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/gtd_database.dart' show Tag;
import '../../providers/tag_filter_provider.dart';
import '../../providers/tags_provider.dart';

/// A bottom sheet with rename, recolour, and merge actions for a [tag].
class TagManagementSheet extends ConsumerWidget {
  const TagManagementSheet({super.key, required this.tag});

  final Tag tag;

  static const List<String> _kColors = [
    '#EF4444', '#F97316', '#F59E0B', '#EAB308',
    '#84CC16', '#10B981', '#14B8A6', '#3B82F6',
    '#6366F1', '#8B5CF6', '#EC4899', '#78716C',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D5DB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tag.name,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 20),
            _ActionTile(
              icon: Icons.edit_outlined,
              label: 'Rename',
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(context, ref);
              },
            ),
            _ActionTile(
              icon: Icons.palette_outlined,
              label: 'Recolour',
              onTap: () {
                Navigator.pop(context);
                _showRecolourDialog(context, ref);
              },
            ),
            _ActionTile(
              icon: Icons.merge_outlined,
              label: 'Merge into…',
              onTap: () {
                Navigator.pop(context);
                _showMergeSheet(context, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showRenameDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController(text: tag.name);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename tag'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          textCapitalization: TextCapitalization.words,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final newName = controller.text.trim();
              if (newName.isEmpty) return;
              try {
                await ref.read(tagNotifierProvider).rename(tag.id, newName);
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (_) {
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Could not rename tag')),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showRecolourDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Choose colour'),
        content: SizedBox(
          width: 240,
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemCount: _kColors.length + 1, // +1 for "none"
            itemBuilder: (_, i) {
              if (i == _kColors.length) {
                // "Clear colour" swatch
                return GestureDetector(
                  onTap: () async {
                    try {
                      await ref
                          .read(tagNotifierProvider)
                          .updateColor(tag.id, null);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (_) {
                      if (!ctx.mounted) return;
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('Could not update tag colour'),
                        ),
                      );
                    }
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFFD1D5DB)),
                    ),
                    child: const Icon(Icons.block,
                        size: 16, color: Color(0xFF9CA3AF)),
                  ),
                );
              }
              final hex = _kColors[i];
              final color = _hexToColor(hex);
              final isCurrent = tag.color == hex;
              return GestureDetector(
                onTap: () async {
                  try {
                    await ref
                        .read(tagNotifierProvider)
                        .updateColor(tag.id, hex);
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (_) {
                    if (!ctx.mounted) return;
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                        content: Text('Could not update tag colour'),
                      ),
                    );
                  }
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: isCurrent
                        ? Border.all(
                            color: const Color(0xFF1A1A2E), width: 2)
                        : null,
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showMergeSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _MergeTargetSheet(source: tag),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile(
      {required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: const Color(0xFF6B7280)),
      title: Text(label,
          style: const TextStyle(fontSize: 15, color: Color(0xFF374151))),
      onTap: onTap,
    );
  }
}

class _MergeTargetSheet extends ConsumerWidget {
  const _MergeTargetSheet({required this.source});

  final Tag source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tagsAsync = ref.watch(contextTagsProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D5DB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Merge into…',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A2E),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'All tasks tagged "${source.name}" will be re-tagged.',
              style:
                  const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 12),
            tagsAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, s) =>
                  const Text('Could not load tags'),
              data: (allTags) {
                final targets = allTags
                    .where((t) => t.id != source.id)
                    .toList();
                if (targets.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No other tags to merge into.',
                      style: TextStyle(color: Color(0xFF9CA3AF)),
                    ),
                  );
                }
                return ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: targets.length,
                    itemBuilder: (_, i) {
                      final target = targets[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.label_outlined,
                            color: Color(0xFF6B7280)),
                        title: Text(target.name,
                            style: const TextStyle(
                                fontSize: 15, color: Color(0xFF374151))),
                        onTap: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Confirm merge'),
                              content: Text(
                                'Merge "${source.name}" into "${target.name}"? '
                                'This cannot be undone.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(ctx, false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(ctx, true),
                                  child: const Text('Merge'),
                                ),
                              ],
                            ),
                          );
                          if (confirm != true) return;
                          try {
                            await ref
                                .read(tagNotifierProvider)
                                .merge(source.id, target.id);
                            // If the merged-away tag was in the active
                            // filter, swap it for the target so DAO watchers
                            // keep returning the user's intended results.
                            final filter = ref.read(tagFilterProvider);
                            if (filter.contains(source.id)) {
                              final notifier =
                                  ref.read(tagFilterProvider.notifier);
                              notifier.toggle(source.id);
                              if (!filter.contains(target.id)) {
                                notifier.toggle(target.id);
                              }
                            }
                            if (context.mounted) Navigator.pop(context);
                          } catch (_) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Merge failed')),
                            );
                          }
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

Color _hexToColor(String hex) {
  final clean = hex.replaceFirst('#', '');
  return Color(int.parse('FF$clean', radix: 16));
}
