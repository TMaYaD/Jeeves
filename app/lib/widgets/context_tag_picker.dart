import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../providers/tags_provider.dart';

/// Multi-select chip row for context tags.
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
              FilterChip(
                key: ValueKey(tag.id),
                label: Text('@${tag.name}'),
                selected: assignedIds.contains(tag.id),
                onSelected: (selected) {
                  if (selected) {
                    widget.onAssign(tag);
                  } else {
                    widget.onRemove(tag);
                  }
                },
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
}
