import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/tags_provider.dart';
import '../providers/task_detail_provider.dart';

/// Bottom-sheet multi-select picker for person-typed tags (Waiting For).
///
/// **The sheet pops with the chosen ids** — `Set<String>` on "Done", `null`
/// on cancel, barrier dismissal or system back. The caller awaits that result
/// and performs its own writes and navigation afterwards, so nothing ever
/// navigates while the sheet is still the top route. `null` means cancelled;
/// an empty set means "confirmed with nobody selected", reachable only when
/// [requireSelection] is false.
///
/// Two modes, distinguished by whether [todoId] is given. They differ only in
/// who attaches the delegates to an Outcome:
///
/// - **Write mode** ([todoId] given) — the subject is an existing Outcome.
///   Pre-selects its assigned tags and, on confirm, replaces its person-tag
///   set with the selection via [TaskDetailNotifier.setPersonTags] before
///   returning it.
/// - **Selection-only mode** (no [todoId]) — the sheet attaches nothing; the
///   caller's own routing write does. Used for an Inbox Capture, whose
///   Outcome does not exist yet (ADR-0006: clarifying a Capture *creates* the
///   Outcome) so there is no row to attach to, and by callers whose routing
///   write replaces the person-tag set atomically anyway.
///
/// Independent of mode, the inline "Add person" field persists the new person
/// tag as soon as it is added: creating a person is its own act, and the new
/// tag stays in the catalogue even if the user then cancels the sheet.
class PersonTagPickerSheet extends ConsumerStatefulWidget {
  const PersonTagPickerSheet({
    super.key,
    this.todoId,
    required this.assignedPersonTagIds,
    this.requireSelection = false,
  });

  /// The Outcome to write person tags to. Null in selection-only mode.
  final String? todoId;

  /// IDs of person-tags currently assigned to the todo.
  final Set<String> assignedPersonTagIds;

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

  /// True from the moment "Done" is accepted until the sheet pops. Confirming
  /// is the one path that both writes and pops, so leaving it re-entrant lets
  /// a second tap pop the *caller's* route behind the closing sheet — the
  /// failure this sheet's result-returning contract exists to prevent — and
  /// lets a cancel land a `null` result on top of a write that did commit.
  bool _committing = false;

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

    return PopScope(
      // Back gesture / drag-dismiss during the commit would pop a `null`
      // result out from under a write that is still landing.
      canPop: !_committing,
      child: Padding(
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
                  onPressed:
                      _committing ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: (_committing ||
                          (widget.requireSelection && _selected.isEmpty))
                      ? null
                      : _confirm,
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
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
    if (_committing) return;
    // Freeze the selection before the first await: what gets written and what
    // gets returned must be the same set.
    final selected = Set<String>.unmodifiable(_selected);
    final todoId = widget.todoId;
    setState(() => _committing = true);

    try {
      if (todoId != null) {
        await ref.read(taskDetailNotifierProvider(todoId)).setPersonTags(
              selected,
            );
      }
    } catch (e) {
      debugPrint('Failed to save person tags: $e');
      if (!mounted) return;
      setState(() => _committing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save. Please try again.')),
      );
      // Stay open on failure: popping with a result would tell the caller a
      // delegate set landed that did not.
      return;
    }

    if (mounted) Navigator.pop(context, selected);
  }
}

/// Shows the [PersonTagPickerSheet] as a modal bottom sheet and returns the
/// chosen person-tag ids, or `null` if the user cancelled.
///
/// The caller performs its own writes and navigation on the result — the
/// sheet has already closed by the time this future completes. Pass [todoId]
/// to have the sheet write the diff onto an existing Outcome; omit it to
/// collect the selection without writing. [requireSelection] disables "Done"
/// until at least one person is selected.
Future<Set<String>?> showPersonTagPicker(
  BuildContext context, {
  String? todoId,
  required Set<String> assignedPersonTagIds,
  bool requireSelection = false,
}) {
  return showModalBottomSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => PersonTagPickerSheet(
      todoId: todoId,
      assignedPersonTagIds: assignedPersonTagIds,
      requireSelection: requireSelection,
    ),
  );
}
