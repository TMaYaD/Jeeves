import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/database_provider.dart';
import '../providers/tags_provider.dart';
import '../utils/tag_colors.dart';

/// Multi-select chip row for context tags.
///
/// FilterChips remain for interactive select/deselect; the chip label is
/// colored with the tag's stored color so the visual language matches
/// [TagText] elsewhere in the app.  Long-pressing a chip opens a palette
/// color picker so the user can change the tag's color.
class ContextTagPickerWidget extends ConsumerStatefulWidget {
  const ContextTagPickerWidget({
    super.key,
    required this.assignedTags,
    required this.onAssign,
    required this.onRemove,
  });

  final List<Tag> assignedTags;
  final ValueChanged<Tag> onAssign;
  final ValueChanged<Tag> onRemove;

  @override
  ConsumerState<ContextTagPickerWidget> createState() =>
      _ContextTagPickerWidgetState();
}

class _ContextTagPickerWidgetState
    extends ConsumerState<ContextTagPickerWidget> {
  bool _creatingNew = false;
  final _newContextController = TextEditingController();

  @override
  void dispose() {
    _newContextController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allContextsAsync = ref.watch(contextTagsProvider);
    final allContexts = allContextsAsync.asData?.value ?? [];
    final assignedIds = widget.assignedTags.map((t) => t.id).toSet();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final tag in allContexts)
              GestureDetector(
                onLongPress: () => _showColorPicker(context, tag),
                child: FilterChip(
                  key: ValueKey(tag.id),
                  label: Text(
                    '@${tag.name}',
                    style: TextStyle(
                      color: resolvedTagColor(
                          name: tag.name, storedHex: tag.color),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  selected: assignedIds.contains(tag.id),
                  onSelected: (selected) {
                    if (selected) {
                      widget.onAssign(tag);
                    } else {
                      widget.onRemove(tag);
                    }
                  },
                ),
              ),
            if (_creatingNew)
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _newContextController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixText: '@',
                    hintText: 'context',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    isDense: true,
                  ),
                  onSubmitted: _createContext,
                ),
              )
            else
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('New context'),
                onPressed: () => setState(() => _creatingNew = true),
              ),
          ],
        ),
        if (_creatingNew)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: () =>
                      _createContext(_newContextController.text),
                  child: const Text('Add'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() {
                    _creatingNew = false;
                    _newContextController.clear();
                  }),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _createContext(String value) async {
    final name = value.trim();
    if (name.isEmpty) return;
    setState(() {
      _creatingNew = false;
      _newContextController.clear();
    });
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
