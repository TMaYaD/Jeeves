import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/tags_provider.dart';
import '../providers/task_detail_provider.dart';

/// Bottom-sheet multi-select picker for person-typed tags (Waiting For).
///
/// Pre-selects the tags already assigned to the todo. On confirm, diffs the
/// selection and calls [TaskDetailNotifier.assignPersonTag] /
/// [TaskDetailNotifier.removePersonTag].  Clearing all selections calls
/// [TaskDetailNotifier.clearAllPersonTags].
class PersonTagPickerSheet extends ConsumerStatefulWidget {
  const PersonTagPickerSheet({
    super.key,
    required this.todoId,
    required this.assignedPersonTagIds,
  });

  final String todoId;

  /// IDs of person-tags currently assigned to the todo.
  final Set<String> assignedPersonTagIds;

  @override
  ConsumerState<PersonTagPickerSheet> createState() =>
      _PersonTagPickerSheetState();
}

class _PersonTagPickerSheetState extends ConsumerState<PersonTagPickerSheet> {
  late Set<String> _selected;
  final _searchController = TextEditingController();
  final _newPersonController = TextEditingController();
  bool _creatingNew = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.assignedPersonTagIds);
    _searchController.addListener(() {
      setState(() => _filter = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _newPersonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allPersonTagsAsync = ref.watch(personTagsProvider);
    final allPersonTags = allPersonTagsAsync.asData?.value ?? [];
    final visible = _filter.isEmpty
        ? allPersonTags
        : allPersonTags
            .where((t) => t.name.toLowerCase().contains(_filter))
            .toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        left: 24,
        right: 24,
        top: 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Waiting For',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            autofocus: false,
            decoration: const InputDecoration(
              hintText: 'Search people…',
              prefixIcon: Icon(Icons.search, size: 20),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          if (visible.isEmpty && _filter.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No match for "$_filter"',
                style: TextStyle(
                    fontSize: 14, color: Theme.of(context).hintColor),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: visible.length,
                itemBuilder: (_, i) {
                  final tag = visible[i];
                  final isSelected = _selected.contains(tag.id);
                  return CheckboxListTile(
                    value: isSelected,
                    title: Text(tag.name),
                    dense: true,
                    onChanged: (_) => setState(() {
                      if (isSelected) {
                        _selected.remove(tag.id);
                      } else {
                        _selected.add(tag.id);
                      }
                    }),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
          if (_creatingNew)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newPersonController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Person name',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    textCapitalization: TextCapitalization.words,
                    onSubmitted: (_) => _createAndSelect(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _createAndSelect,
                  child: const Text('Add'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _creatingNew = false;
                    _newPersonController.clear();
                  }),
                  child: const Text('Cancel'),
                ),
              ],
            )
          else
            TextButton.icon(
              onPressed: () => setState(() => _creatingNew = true),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add person'),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _confirm,
                child: const Text('Done'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _createAndSelect() async {
    final name = _newPersonController.text.trim();
    if (name.isEmpty) return;
    try {
      final db = ref.read(databaseProvider);
      final userId = ref.read(currentUserIdProvider);
      final tagId = await db.tagDao.createPersonTag(name, userId);
      if (mounted) {
        setState(() {
          _creatingNew = false;
          _newPersonController.clear();
          _selected.add(tagId);
        });
      }
    } catch (e) {
      debugPrint('Failed to create person tag: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to create tag. Please try again.')),
        );
      }
    }
  }

  Future<void> _confirm() async {
    final notifier = ref.read(taskDetailNotifierProvider(widget.todoId));
    final added = _selected.difference(widget.assignedPersonTagIds);
    final removed = widget.assignedPersonTagIds.difference(_selected);

    for (final tagId in added) {
      await notifier.assignPersonTag(tagId);
    }
    for (final tagId in removed) {
      await notifier.removePersonTag(tagId);
    }

    if (mounted) Navigator.pop(context);
  }
}

/// Shows the [PersonTagPickerSheet] as a modal bottom sheet.
Future<void> showPersonTagPicker(
  BuildContext context, {
  required String todoId,
  required Set<String> assignedPersonTagIds,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => PersonTagPickerSheet(
      todoId: todoId,
      assignedPersonTagIds: assignedPersonTagIds,
    ),
  );
}
