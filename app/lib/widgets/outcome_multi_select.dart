import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/todo_dao.dart' show StalePersonSelectionException;
import '../database/gtd_database.dart';
import '../models/routing_kind.dart';
import '../providers/auth_provider.dart';
import '../providers/database_provider.dart';
import '../providers/task_detail_provider.dart';
import 'context_tag_picker.dart';
import 'outcome_row.dart';
import 'person_tag_picker.dart';
import 'project_picker.dart';

/// An [OutcomeRow] that follows the list multi-select convention: out of
/// selection mode a tap opens the Outcome and a long-press enters the mode with
/// this Outcome selected (a null [onEnterSelection] disables that); in the mode the row shows a leading checkbox, hides
/// its chevron and a tap toggles it.
Widget selectableOutcomeRow({
  required Todo todo,
  required bool selectionActive,
  required bool selected,
  required VoidCallback onOpen,
  required VoidCallback onToggle,
  required VoidCallback? onEnterSelection,
}) {
  return OutcomeRow(
    title: todo.title,
    energyLevel: todo.energyLevel,
    timeEstimateMinutes: todo.timeEstimate,
    dueDate: todo.dueDate,
    leading: selectionActive
        ? Checkbox(value: selected, onChanged: (_) => onToggle())
        : null,
    trailing: selectionActive ? const SizedBox.shrink() : null,
    onTap: selectionActive ? onToggle : onOpen,
    onLongPress: selectionActive ? null : onEnterSelection,
  );
}

/// Bar above a list while Outcomes are selected: count, select-all, and the
/// three bulk actions (Project, Tags, Status). Each action is one DAO call that
/// writes in a single transaction and skips any Outcome deleted meanwhile.
class OutcomeSelectionBar extends ConsumerWidget {
  const OutcomeSelectionBar({
    super.key,
    required this.selectedIds,
    required this.allIds,
    required this.onClear,
    required this.onSelectAll,
  });

  final Set<String> selectedIds;
  final Set<String> allIds;
  final VoidCallback onClear;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = selectedIds.length;
    final allSelected = count >= allIds.length;
    // Resolved while this bar is alive: the pickers below finish later, and
    // sync can drop the last selected Outcome (unmounting the bar) meanwhile.
    final database = ref.read(databaseProvider);
    final userId = ref.read(currentUserIdProvider);
    return Semantics(
      label: '$count selected',
      container: true,
      child: Material(
        color: const Color(0xFFEFF6FF),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Clear selection',
                    icon: const Icon(Icons.close, size: 20),
                    color: const Color(0xFF374151),
                    onPressed: onClear,
                  ),
                  Expanded(
                    child: Text(
                      '$count selected',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                  ),
                  if (!allSelected)
                    TextButton(
                      onPressed: onSelectAll,
                      child: const Text('Select all'),
                    ),
                ],
              ),
              // Wrap, not Row: the three actions flow onto a second line rather
              // than overflow on a narrow phone.
              Wrap(
                alignment: WrapAlignment.spaceEvenly,
                children: [
                  ProjectPickerWidget(
                    currentProjectTag: null,
                    onClear: () {},
                    onAssign: (tag) => database.tagDao
                        .setProjectForOutcomes(selectedIds, tag.id, userId)
                        .ignore(),
                    customChild: const _BarButton(
                        icon: Icons.folder_outlined, label: 'Project'),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _showTagsSheet(context, selectedIds),
                    child: const _BarButton(
                        icon: Icons.sell_outlined, label: 'Tags'),
                  ),
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _showStatusSheet(
                        context, database, userId, selectedIds, onClear),
                    child: const _BarButton(
                        icon: Icons.flag_outlined, label: 'Status'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: const Color(0xFF2563EB)),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2563EB))),
        ],
      ),
    );
  }
}

Future<void> _showTagsSheet(BuildContext context, Set<String> ids) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          left: 24,
          right: 24,
          top: 24),
      child: _BulkTagsSheet(ids: ids),
    ),
  );
}

/// Hosts the context-tag picker. A Tag shows ticked only when **every**
/// selected Outcome carries it; one tap on an unticked Tag applies it to all.
class _BulkTagsSheet extends ConsumerWidget {
  const _BulkTagsSheet({required this.ids});
  final Set<String> ids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Set<String>? common;
    final byId = <String, Tag>{};
    for (final id in ids) {
      final tags = ref.watch(taskTagsProvider(id)).asData?.value ?? const <Tag>[];
      final contextTags = tags.where((t) => t.type == 'context');
      for (final t in contextTags) {
        byId[t.id] = t;
      }
      final idsHere = {for (final t in contextTags) t.id};
      common = common == null ? idsHere : common.intersection(idsHere);
    }
    final assigned = [for (final id in common ?? <String>{}) byId[id]!];
    final tagDao = ref.read(databaseProvider).tagDao;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tags for ${ids.length} selected',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        ContextTagPickerWidget(
          assignedTags: assigned,
          onAssign: (tag) => tagDao
              .assignTagToOutcomes(ids, tag.id, ref.read(currentUserIdProvider))
              .ignore(),
          onRemove: (tag) => tagDao.removeTagFromOutcomes(ids, tag.id).ignore(),
        ),
      ],
    );
  }
}

Future<void> _showStatusSheet(BuildContext context, GtdDatabase database,
    String? userId, Set<String> ids, VoidCallback onDone) async {
  final choice = await showModalBottomSheet<RoutingKind>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (kind, label, icon) in const [
            (RoutingKind.nextAction, 'Next', Icons.play_arrow_outlined),
            (RoutingKind.waitingFor, 'Waiting For', Icons.people_outline),
            (RoutingKind.maybe, 'Someday/Maybe', Icons.cloud_outlined),
            (RoutingKind.done, 'Done', Icons.check_circle_outline),
            (RoutingKind.trash, 'Trash', Icons.delete_outline),
          ])
            ListTile(
              leading: Icon(icon),
              title: Text(label),
              onTap: () => Navigator.of(ctx).pop(kind),
            ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  Set<String>? people;
  if (choice == RoutingKind.waitingFor) {
    people = await showPersonTagPicker(context,
        assignedPersonTagIds: const {}, requireSelection: true);
    if (people == null) return; // cancelled: nothing is written
    if (!context.mounted) return;
  }
  final dao = database.todoDao;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await dao.applyRoutingToOutcomes(
      ids,
      to: choice,
      // Next clears PersonBlockers and Waiting For replaces them, so the status
      // pill reads the chosen status afterwards; the other routes keep them.
      personTagIds: switch (choice) {
        RoutingKind.nextAction => const <String>{},
        RoutingKind.waitingFor => people,
        _ => null,
      },
      userId: userId,
    );
  } on StalePersonSelectionException {
    // Nothing was written; keep the selection so the user can choose again.
    messenger?.showSnackBar(const SnackBar(
        content: Text('That Person no longer exists. Choose again.')));
    return;
  }
  onDone();
}
