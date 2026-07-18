import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/tags_provider.dart';
import '../providers/task_detail_provider.dart';

/// Bottom-sheet multi-select picker for person-typed tags (Waiting For).
///
/// Two modes, exactly one of which must be selected by the caller:
///
/// - **Write mode** ([todoId] given) — the subject is an existing Outcome.
///   Pre-selects its assigned tags and, on confirm, diffs the selection and
///   calls [TaskDetailNotifier.assignPersonTag] /
///   [TaskDetailNotifier.removePersonTag]. Clearing all selections calls
///   [TaskDetailNotifier.clearAllPersonTags].
/// - **Selection-only mode** ([onConfirmSelection] given) — the subject is an
///   Inbox Capture. Its Outcome does not exist yet (ADR-0006: clarifying a
///   Capture *creates* the Outcome), so there is no row to attach person tags
///   to. The sheet writes nothing and hands the chosen set back for
///   [ClarificationService.clarifyCaptureToOutcome] to apply to the Outcome it
///   mints.
class PersonTagPickerSheet extends ConsumerStatefulWidget {
  const PersonTagPickerSheet({
    super.key,
    this.todoId,
    required this.assignedPersonTagIds,
    this.onAfterConfirm,
    this.onConfirmSelection,
    this.requireSelection = false,
  }) : assert(
          (todoId == null) != (onConfirmSelection == null),
          'Pass todoId to write tags onto an existing Outcome, or '
          'onConfirmSelection to collect them for a Capture whose Outcome does '
          'not exist yet — exactly one, never both.',
        );

  /// The Outcome to write person tags to. Null in selection-only mode.
  final String? todoId;

  /// IDs of person-tags currently assigned to the todo.
  final Set<String> assignedPersonTagIds;

  /// Called after tag assignments complete when the user taps "Done".
  /// Use this to perform caller-specific side-effects (e.g., clarifying an
  /// inbox item) that should only run on explicit confirmation, not on cancel.
  final Future<void> Function()? onAfterConfirm;

  /// Selection-only mode: receives the chosen person-tag ids on "Done"
  /// instead of the sheet writing them. See the class doc.
  final Future<void> Function(Set<String> selected)? onConfirmSelection;

  /// When true, "Done" is a no-op if no person is selected — prevents routing
  /// without a waiter (e.g., the inbox "Waiting For" destination).
  final bool requireSelection;

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
                onPressed: (widget.requireSelection && _selected.isEmpty)
                    ? null
                    : _confirm,
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
    final collect = widget.onConfirmSelection;
    if (collect != null) {
      // Selection-only: nothing exists to write to yet. The caller passes the
      // set straight into clarifyCaptureToOutcome, which attaches it to the
      // Outcome it creates in the same transaction.
      await collect(Set.unmodifiable(_selected));
      if (mounted) Navigator.pop(context);
      return;
    }

    final notifier = ref.read(taskDetailNotifierProvider(widget.todoId!));
    final added = _selected.difference(widget.assignedPersonTagIds);
    final removed = widget.assignedPersonTagIds.difference(_selected);

    for (final tagId in added) {
      await notifier.assignPersonTag(tagId);
    }
    for (final tagId in removed) {
      await notifier.removePersonTag(tagId);
    }

    await widget.onAfterConfirm?.call();

    if (mounted) Navigator.pop(context);
  }
}

/// Shows the [PersonTagPickerSheet] as a modal bottom sheet.
///
/// [onAfterConfirm] is called after tag assignments when the user taps "Done".
/// [requireSelection] disables "Done" until at least one person is selected.
Future<void> showPersonTagPicker(
  BuildContext context, {
  String? todoId,
  required Set<String> assignedPersonTagIds,
  Future<void> Function()? onAfterConfirm,
  Future<void> Function(Set<String> selected)? onConfirmSelection,
  bool requireSelection = false,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => PersonTagPickerSheet(
      todoId: todoId,
      assignedPersonTagIds: assignedPersonTagIds,
      onAfterConfirm: onAfterConfirm,
      onConfirmSelection: onConfirmSelection,
      requireSelection: requireSelection,
    ),
  );
}
