import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/follow_up_change.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/tags_provider.dart';
import '../providers/task_detail_provider.dart';

/// What the sheet hands back: the chosen people and, when the sheet offered a
/// follow-up date and the user changed it, that change. [followUp] is null when
/// the row was not offered or left as it was.
class PersonPickerResult {
  const PersonPickerResult(this.people, {this.followUp});

  final Set<String> people;
  final FollowUpChange? followUp;
}

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
///   returning it. If the Outcome is gone from local storage when Done is
///   tapped, nothing is written and the sheet pops `null`, as for cancel.
/// - **Selection-only mode** (no [todoId]) — the sheet attaches nothing; the
///   caller's own routing write does. Used for an Inbox Capture, whose
///   Outcome does not exist yet (ADR-0006: clarifying a Capture *creates* the
///   Outcome) so there is no row to attach to, and by callers whose routing
///   write replaces the person-tag set atomically anyway.
///
/// Independent of mode, both ways of adding a person — `Add "<name>"` from a
/// search that matches nobody, and the "Add person" field — persist the new
/// person tag as soon as it is added: creating a person is its own act, and the
/// new tag stays in the catalogue even if the user then cancels the sheet.
class PersonTagPickerSheet extends ConsumerStatefulWidget {
  const PersonTagPickerSheet({
    super.key,
    this.todoId,
    required this.assignedPersonTagIds,
    this.requireSelection = false,
    this.offerFollowUp = false,
    this.initialFollowUpDate,
  });

  /// Shows the optional "Follow up from" date row. Only the routing bar to
  /// Waiting For asks for it.
  final bool offerFollowUp;

  /// The follow-up date the Outcome already carries, if any. Shown on the row;
  /// the result carries a [FollowUpChange] only if the user moves away from it.
  final DateTime? initialFollowUpDate;

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

  /// The search text as typed (trimmed, original casing). [_filter] is its
  /// lowercased match key and must never be used as a name.
  String _searchText = '';

  /// True while a person tag is being created, so a second tap cannot run a
  /// concurrent create.
  bool _addingPerson = false;

  /// True from the moment "Done" is accepted until the sheet pops. Confirming
  /// is the one path that both writes and pops, so leaving it re-entrant lets
  /// a second tap pop the *caller's* route behind the closing sheet — the
  /// failure this sheet's result-returning contract exists to prevent — and
  /// lets a cancel land a `null` result on top of a write that did commit.
  bool _committing = false;

  /// The follow-up date on the row; starts at [initialFollowUpDate].
  DateTime? _followUpDate;

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.assignedPersonTagIds);
    final initial = widget.initialFollowUpDate;
    _followUpDate =
        initial == null ? null : DateTime(initial.year, initial.month, initial.day);
    _searchController.addListener(() {
      setState(() {
        _searchText = _searchController.text.trim();
        _filter = _searchText.toLowerCase();
      });
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'No match for "$_searchText"',
                      style: TextStyle(
                          fontSize: 14, color: Theme.of(context).hintColor),
                    ),
                    TextButton.icon(
                      onPressed: _addingPerson
                          ? null
                          : () => _addPerson(_searchText),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text('Add "$_searchText"'),
                    ),
                  ],
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
                    onPressed: _addingPerson ? null : _createAndSelect,
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
            if (widget.offerFollowUp) _followUpRow(context),
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
                          _addingPerson ||
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

  Widget _followUpRow(BuildContext context) {
    final date = _followUpDate;
    final label = date == null
        ? 'Follow up from…'
        : 'Follow up from '
            '${MaterialLocalizations.of(context).formatShortMonthDay(date)}';
    return Row(
      children: [
        TextButton.icon(
          key: const Key('follow-up-from'),
          onPressed: _committing ? null : _pickFollowUpDate,
          icon: const Icon(Icons.event, size: 18),
          label: Text(label),
        ),
        if (date != null)
          IconButton(
            key: const Key('follow-up-clear'),
            tooltip: 'Clear follow-up date',
            icon: const Icon(Icons.close, size: 18),
            onPressed:
                _committing ? null : () => setState(() => _followUpDate = null),
          ),
      ],
    );
  }

  Future<void> _pickFollowUpDate() async {
    final today = DateTime.now();
    final startOfToday = DateTime(today.year, today.month, today.day);
    final lastDate = startOfToday.add(const Duration(days: 365));
    // Same bounds as the Time context sheet's From picker. A stored date can lie
    // outside them, and showDatePicker asserts initialDate is in range, so clamp
    // only what the picker opens on.
    var initialDate = _followUpDate ?? startOfToday;
    if (initialDate.isBefore(startOfToday)) initialDate = startOfToday;
    if (initialDate.isAfter(lastDate)) initialDate = lastDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: startOfToday,
      lastDate: lastDate,
    );
    if (picked != null && mounted) {
      setState(() =>
          _followUpDate = DateTime(picked.year, picked.month, picked.day));
    }
  }

  /// The follow-up change to hand back: null unless the row was offered and the
  /// date now differs from the one the sheet opened with.
  FollowUpChange? _followUpChange() {
    if (!widget.offerFollowUp) return null;
    final initial = widget.initialFollowUpDate;
    final initialDay =
        initial == null ? null : DateTime(initial.year, initial.month, initial.day);
    if (_followUpDate == initialDay) return null;
    final date = _followUpDate;
    return date == null
        ? const FollowUpChange.remove()
        : FollowUpChange.set(date);
  }

  Future<void> _createAndSelect() async {
    if (await _addPerson(_newPersonController.text) && mounted) {
      setState(() {
        _creatingNew = false;
        _newPersonController.clear();
      });
    }
  }

  /// Persists [name] as a person tag and ticks it. Returns whether it landed.
  Future<bool> _addPerson(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || _addingPerson) return false;
    setState(() => _addingPerson = true);
    try {
      final db = ref.read(databaseProvider);
      final userId = ref.read(currentUserIdProvider);
      final tagId = await db.tagDao.createPersonTag(trimmed, userId);
      if (mounted) setState(() => _selected.add(tagId));
      return true;
    } catch (e) {
      debugPrint('Failed to create person tag: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to add person. Please try again.')),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _addingPerson = false);
    }
  }

  Future<void> _confirm() async {
    if (_committing || _addingPerson) return;
    // Freeze the selection before the first await: what gets written and what
    // gets returned must be the same set.
    final selected = Set<String>.unmodifiable(_selected);
    final todoId = widget.todoId;
    setState(() => _committing = true);

    var landed = true;
    try {
      if (todoId != null) {
        landed = await ref
            .read(taskDetailNotifierProvider(todoId))
            .setPersonTags(selected);
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

    // The Outcome was deleted while the sheet was open: nothing was written,
    // so close as a cancel rather than report a selection that did not land.
    if (mounted) {
      Navigator.pop(
        context,
        landed ? PersonPickerResult(selected, followUp: _followUpChange()) : null,
      );
    }
  }
}

/// Shows the [PersonTagPickerSheet] as a modal bottom sheet and returns the
/// chosen person-tag ids, or `null` if the user cancelled or nothing landed
/// (the Outcome was deleted while the sheet was open).
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
}) async {
  final result = await showPersonPicker(
    context,
    todoId: todoId,
    assignedPersonTagIds: assignedPersonTagIds,
    requireSelection: requireSelection,
  );
  return result?.people;
}

/// [showPersonTagPicker] with the full result, optionally offering the
/// "Follow up from" date row ([offerFollowUp], starting from
/// [initialFollowUpDate]).
Future<PersonPickerResult?> showPersonPicker(
  BuildContext context, {
  String? todoId,
  required Set<String> assignedPersonTagIds,
  bool requireSelection = false,
  bool offerFollowUp = false,
  DateTime? initialFollowUpDate,
}) {
  return showModalBottomSheet<PersonPickerResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    builder: (_) => PersonTagPickerSheet(
      todoId: todoId,
      assignedPersonTagIds: assignedPersonTagIds,
      requireSelection: requireSelection,
      offerFollowUp: offerFollowUp,
      initialFollowUpDate: initialFollowUpDate,
    ),
  );
}
