import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/database_provider.dart';
import '../providers/tags_provider.dart';
import '../utils/tag_colors.dart';
import 'dotted_add_button.dart';
import 'tag_cloud_view.dart';
import 'tag_list.dart';

/// Context-tag editor: the applied tags and a dotted `+` that reveals the
/// searchable tag cloud (the drawer's cloud, plus `Add "<name>"` for a name no
/// tag has yet). Long-pressing a tag opens a palette color picker.
class ContextTagPickerWidget extends ConsumerStatefulWidget {
  const ContextTagPickerWidget({
    super.key,
    required this.assignedTags,
    required this.onAssign,
    required this.onRemove,
    this.cloudInitiallyOpen = false,
  });

  final List<Tag> assignedTags;
  final ValueChanged<Tag> onAssign;
  final ValueChanged<Tag> onRemove;
  final bool cloudInitiallyOpen;

  @override
  ConsumerState<ContextTagPickerWidget> createState() =>
      _ContextTagPickerWidgetState();
}

class _ContextTagPickerWidgetState
    extends ConsumerState<ContextTagPickerWidget> {
  late bool _cloudOpen = widget.cloudInitiallyOpen;

  @override
  Widget build(BuildContext context) {
    final assignedIds = widget.assignedTags.map((t) => t.id).toSet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TagList(
          tags: widget.assignedTags,
          spacing: 12,
          runSpacing: 8,
          onTap: widget.onRemove,
          onDismiss: widget.onRemove,
          onLongPress: (tag) => _showColorPicker(context, tag),
          trailing: DottedAddButton(
            key: const Key('context_tag_picker_add'),
            onTap: () => setState(() => _cloudOpen = !_cloudOpen),
          ),
        ),
        if (_cloudOpen)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Consumer(
              builder: (context, ref, _) {
                final tags =
                    ref.watch(contextTagsWithCountProvider).asData?.value ??
                        const <TagWithCount>[];
                return TagCloudView(
                  key: const Key('context_tag_picker_cloud'),
                  tags: tags,
                  selectedIds: assignedIds,
                  includeUnusedTags: true,
                  alwaysOfferFindField: true,
                  onTap: (tag) => assignedIds.contains(tag.id)
                      ? widget.onRemove(tag)
                      : widget.onAssign(tag),
                  onLongPress: (tag) => _showColorPicker(context, tag),
                  onCreateTag: _createContext,
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _createContext(String name) async {
    final tag =
        await ref.read(tagNotifierProvider).createTag(name, 'context');
    widget.onAssign(tag);
  }

  Future<void> _showColorPicker(BuildContext context, Tag tag) async {
    final chosen = await showModalBottomSheet<Color>(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => _TagColorPickerSheet(tag: tag),
    );
    if (chosen == null) return;
    final db = ref.read(databaseProvider);
    await db.tagDao.upsertTag(
      TagsCompanion(
        id: Value(tag.id),
        color: Value(tagColorToHex(chosen)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Color-picker bottom sheet
// ---------------------------------------------------------------------------

class _TagColorPickerSheet extends StatelessWidget {
  const _TagColorPickerSheet({required this.tag});
  final Tag tag;

  @override
  Widget build(BuildContext context) {
    final current =
        resolvedTagColor(name: tag.name, storedHex: tag.color);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Color for @${tag.name}',
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: kTagPalette.map((color) {
              final isSelected = color.toARGB32() == current.toARGB32();
              return GestureDetector(
                onTap: () => Navigator.of(context).pop(color),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? color : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      'Aa',
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
