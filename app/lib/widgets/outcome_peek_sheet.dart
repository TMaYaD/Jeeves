/// A read-only bottom sheet that peeks at an Outcome's fuller details during
/// Daily Planning (#462).
///
/// Opened by a plain tap on a Plan Summary card (outside multi-select). It
/// shows title, notes, energy, time estimate, due date, and time logged, and
/// is **read-only by construction** — the sheet renders `Text`/icon rows only,
/// with no `TextField`, picker, edit handler, or navigation to the edit
/// surface. Nothing here writes to the database or to planning state, so
/// opening or dismissing the sheet has no side effect on the pick-up/skip
/// selection (the modal sits *over* the never-unmounted list, preserving scroll
/// and selection).
///
/// Time logged is derived from the `time_logs` table via
/// [TimeLogDao.totalMinutesForTask], not the `todos.time_spent_minutes` cursor
/// column, whose freshness is being verified separately.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../database/gtd_database.dart';
import '../providers/database_provider.dart';
import 'meta_chip.dart';

/// One-shot read of the ceiling-rounded minutes logged against [taskId],
/// summed from the `time_logs` rows. Resolved fresh each time the sheet
/// opens — `.autoDispose` drops the cached value once nothing is watching
/// it, so re-opening the peek for the same task re-reads
/// [TimeLogDao.totalMinutesForTask] instead of replaying a stale total.
final outcomePeekTimeLoggedProvider =
    FutureProvider.autoDispose.family<int, String>((ref, taskId) {
  return ref.watch(databaseProvider).timeLogDao.totalMinutesForTask(taskId);
});

class OutcomePeekSheet extends ConsumerWidget {
  const OutcomePeekSheet({super.key, required this.todo});

  final Todo todo;

  /// Opens the read-only peek sheet for [todo]. Dismissal performs no side
  /// effects; the caller's scroll and selection state are untouched.
  static Future<void> show(BuildContext context, Todo todo) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        // Sheets sit at 6px on the canonical 2/4/6 scale (DESIGN.md §Roundedness).
        borderRadius: BorderRadius.vertical(top: Radius.circular(6)),
      ),
      builder: (_) => OutcomePeekSheet(todo: todo),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = todo.notes;
    final dueDate = todo.dueDate;
    final energyLevel = todo.energyLevel;
    final timeEstimate = todo.timeEstimate;
    final timeLogged = ref.watch(outcomePeekTimeLoggedProvider(todo.id));

    return Semantics(
      label: 'Outcome details',
      container: true,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle for affordance.
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              // Header: title + close.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      todo.title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A2E),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Close',
                    child: InkWell(
                      onTap: () => Navigator.of(context).maybePop(),
                      borderRadius: BorderRadius.circular(4),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close,
                            size: 22, color: Color(0xFF6B7280)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Meta chips: energy, time estimate, time logged, due date.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (energyLevel != null)
                    MetaChip(
                      icon: Icons.bolt_outlined,
                      label: energyLevelLabel(energyLevel),
                      color: const Color(0xFF7C3AED),
                    ),
                  if (timeEstimate != null)
                    MetaChip(
                      icon: Icons.timer_outlined,
                      label: formatMinutesLabel(timeEstimate),
                      color: const Color(0xFF2563EB),
                    ),
                  _TimeLoggedChip(value: timeLogged),
                  if (dueDate != null)
                    MetaChip(
                      icon: Icons.event_outlined,
                      label: DateFormat('MMM d, y').format(dueDate),
                      color: const Color(0xFFDC2626),
                    ),
                ],
              ),

              // Notes — omitted entirely when null/empty.
              if (notes != null && notes.trim().isNotEmpty) ...[
                const SizedBox(height: 20),
                const _FieldLabel('Notes'),
                const SizedBox(height: 6),
                Flexible(
                  child: SingleChildScrollView(
                    child: Text(
                      notes,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: Color(0xFF374151),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The time-logged chip. Renders a subtle placeholder while the one-shot read
/// resolves; `0` shows as "no time logged yet".
class _TimeLoggedChip extends StatelessWidget {
  const _TimeLoggedChip({required this.value});

  final AsyncValue<int> value;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF16A34A);
    final label = value.when(
      data: (minutes) =>
          minutes <= 0 ? 'No time logged yet' : formatMinutesLabel(minutes),
      loading: () => '…',
      error: (_, _) => '—',
    );
    return MetaChip(
      icon: Icons.history_toggle_off_outlined,
      label: label,
      color: color,
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}
