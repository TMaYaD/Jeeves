import 'package:flutter/material.dart' hide Intent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/gtd_database.dart';
import '../models/todo.dart' show Intent, RoutingKind;
import '../providers/task_detail_provider.dart';
import 'person_tag_picker.dart';

/// Tappable status pill for the task detail header.
///
/// Derives a human-readable label from the todo's state and person-tags, and
/// opens a status-menu sheet on tap that lets the user change the intent or
/// manage Waiting For assignments.
class TaskStatusRow extends ConsumerWidget {
  const TaskStatusRow({
    super.key,
    required this.todo,
    required this.tags,
  });

  final Todo todo;
  final List<Tag> tags;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final personTags = tags.where((t) => t.type == 'person').toList();
    final label = _label(personTags);
    final color = _dotColor(personTags);

    return GestureDetector(
      onTap: () => _showStatusMenu(context, ref, personTags),
      child: Container(
        key: const Key('status_pill'),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 6,
              height: 6,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF4B5563),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Trash is checked before Completion: a completed-then-trashed Outcome
  // surfaces in Trash only — the discard stance wins over the historical
  // Completion fact (CONTEXT.md § Done / Trash).
  String _label(List<Tag> personTags) {
    if (todo.intent == 'trash') return 'Trashed';
    if (todo.doneAt != null) return 'Done';
    if (todo.intent == 'maybe') return 'Someday';
    if (personTags.isNotEmpty) {
      final names = personTags.map((t) => t.name).join(' & ');
      return 'Waiting For $names';
    }
    return 'Next Actions';
  }

  Color _dotColor(List<Tag> personTags) {
    if (todo.intent == 'trash') return const Color(0xFFEF4444);
    if (todo.doneAt != null) return const Color(0xFF6B7280);
    if (todo.intent == 'maybe') return const Color(0xFFF59E0B);
    if (personTags.isNotEmpty) return const Color(0xFFF59E0B);
    return const Color(0xFF10B981);
  }

  void _showStatusMenu(
      BuildContext context, WidgetRef ref, List<Tag> personTags) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => _StatusMenuSheet(
        todo: todo,
        personTags: personTags,
      ),
    );
  }
}

class _StatusMenuSheet extends ConsumerWidget {
  const _StatusMenuSheet({
    required this.todo,
    required this.personTags,
  });

  final Todo todo;
  final List<Tag> personTags;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(taskDetailNotifierProvider(todo.id));

    // Every write below goes through this rather than straight to [notifier].
    // The sheet lives on its own modal route, so an Outcome deleted underneath
    // it — sync applying a remote delete, say — neither dismisses it nor
    // disables these tiles: the user is left choosing a status for a row that
    // is gone. `AsyncData(null)` is the same "gone, not loading" test
    // `AsyncSubject` makes; see `TaskDetailScreen._mutate`, which guards the
    // sheets that screen owns for the same reason.
    Future<void> write(Future<void> Function(TaskDetailNotifier n) mutate) async {
      final subject = ref.read(taskDetailTodoProvider(todo.id));
      if (subject.hasValue && subject.value == null) return;
      await mutate(notifier);
    }
    final isDone = todo.doneAt != null;
    final isTrashed = todo.intent == 'trash';
    final isMaybe = todo.intent == 'maybe';
    final isWaiting = personTags.isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(
                'Set Status',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(color: Color(0xFFF3F4F6)),
            // Next — only shown when currently waiting
            if (isWaiting)
              ListTile(
                leading: const Icon(Icons.check_circle_outline,
                    color: Color(0xFF10B981)),
                title: const Text('Next'),
                onTap: () async {
                  Navigator.pop(context);
                  await write((n) => n.clearAllPersonTags());
                },
              ),
            // Next Actions — only shown when currently in Someday/Maybe
            if (isMaybe)
              ListTile(
                leading: const Icon(Icons.check_circle_outline,
                    color: Color(0xFF10B981)),
                title: const Text('Next Actions'),
                onTap: () async {
                  Navigator.pop(context);
                  await write((n) => n.setIntent(Intent.next));
                },
              ),
            // Waiting For >
            ListTile(
              leading: const Icon(Icons.hourglass_empty_outlined,
                  color: Color(0xFFF59E0B)),
              title: const Text('Waiting For ›'),
              onTap: () {
                Navigator.pop(context);
                showPersonTagPicker(
                  context,
                  todoId: todo.id,
                  assignedPersonTagIds:
                      personTags.map((t) => t.id).toSet(),
                );
              },
            ),
            // Someday — not shown when already someday/done/trashed
            if (!isMaybe && !isDone && !isTrashed)
              ListTile(
                leading: const Icon(Icons.wb_sunny_outlined,
                    color: Color(0xFFF59E0B)),
                title: const Text('Someday'),
                onTap: () async {
                  Navigator.pop(context);
                  await write((n) => n.setIntent(Intent.maybe));
                },
              ),
            // Done — not shown when already done
            if (!isDone)
              ListTile(
                leading: const Icon(Icons.task_alt,
                    color: Color(0xFF10B981)),
                title: const Text('Done'),
                onTap: () async {
                  Navigator.pop(context);
                  await write((n) => n.markDone());
                },
              ),
            // Trash — not shown when already trashed
            if (!isTrashed)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Color(0xFFEF4444)),
                title: const Text('Trash'),
                onTap: () async {
                  Navigator.pop(context);
                  await write((n) => n.setIntent(Intent.trash));
                },
              ),
            // Restore — a trashed Outcome chooses the Intent to return to
            // (issue #408); a done-only Outcome keeps single-tap restore to
            // Next. Both paths route through applyRouting, which clears
            // done_at and stamps last_clarified_at.
            if (isTrashed) ...[
              ListTile(
                leading: const Icon(Icons.restore, color: Color(0xFF2563EB)),
                title: const Text('Restore to Next'),
                onTap: () async {
                  Navigator.pop(context);
                  await write((n) => n.restoreTo(RoutingKind.nextAction));
                },
              ),
              ListTile(
                leading: const Icon(Icons.restore, color: Color(0xFF2563EB)),
                title: const Text('Restore to Someday/Maybe'),
                onTap: () async {
                  Navigator.pop(context);
                  await write((n) => n.restoreTo(RoutingKind.maybe));
                },
              ),
            ] else if (isDone)
              ListTile(
                leading: const Icon(Icons.restore, color: Color(0xFF2563EB)),
                title: const Text('Restore'),
                onTap: () async {
                  Navigator.pop(context);
                  await write((n) => n.restoreTo(RoutingKind.nextAction));
                },
              ),
          ],
        ),
      ),
    );
  }
}
