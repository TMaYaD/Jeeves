library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/evening_shutdown_provider.dart';
import '../../../widgets/meta_chip.dart';
import '../../../widgets/outcome_row.dart';

/// Step 0 of the shutdown ritual: the day's **Settled** Outcomes, grouped by
/// how each settled.
///
/// Everything the user resolved during the day appears here — achieved work and
/// work they answered for some other way ("more work later", "waiting on
/// someone", "defer") — so the disposition step that follows only has to ask
/// about what is genuinely still open (#694).
///
/// Actual time spent is derived from `time_logs` via
/// [loggedMinutesByOutcomeProvider] — no Outcome row carries a total. The map is
/// read once for the whole step and serves both the per-card chip and the
/// summary bar's fold, so the two can never disagree.
class SettledReviewStep extends ConsumerWidget {
  const SettledReviewStep({super.key});

  /// The heading each group renders under.
  static String _labelFor(SessionSettlement bucket, int count) =>
      switch (bucket) {
        SessionSettlement.done => 'COMPLETED TODAY ($count)',
        SessionSettlement.next => 'MORE WORK LATER ($count)',
        SessionSettlement.waitingFor => 'WAITING ON SOMEONE ($count)',
        SessionSettlement.someday => 'DEFERRED TO SOMEDAY ($count)',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncGroups = ref.watch(sessionSettlementGroupsProvider);
    // Absent while the first emission is in flight, and absent per Outcome that
    // has no stints: an unresolved total reads as 0, which is what the chips
    // suppress on.
    final loggedMinutes =
        ref.watch(loggedMinutesByOutcomeProvider).value ?? const {};

    if (asyncGroups.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (asyncGroups.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
              const SizedBox(height: 16),
              const Text(
                "Could not load today's summary",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final groups = asyncGroups.asData!.value;

    if (groups.isEmpty) {
      return const _EmptySettled();
    }

    // Estimate / actual / accuracy fold over the **completed** group only:
    // an accuracy figure across work that is not finished means nothing.
    final completed = groups[SessionSettlement.done] ?? const <Todo>[];
    final settledCount =
        groups.values.fold<int>(0, (sum, items) => sum + items.length);
    final totalEstimated =
        completed.fold<int>(0, (sum, t) => sum + (t.timeEstimate ?? 0));
    final totalActual = completed.fold<int>(
        0, (sum, t) => sum + (loggedMinutes[t.id] ?? 0));

    return Column(
      children: [
        _SummaryBar(
          settledCount: settledCount,
          completedCount: completed.length,
          totalEstimated: totalEstimated,
          totalActual: totalActual,
        ),
        const Divider(height: 1, color: Color(0xFFF3F4F6)),
        Expanded(
          child: ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(overscroll: false),
            child: ListView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                for (final entry in groups.entries) ...[
                  _SectionLabel(_labelFor(entry.key, entry.value.length)),
                  // The one group with a downstream consequence says so on
                  // screen — that is what makes its Disposition *implicit*
                  // rather than silent.
                  if (entry.key == SessionSettlement.next) ...[
                    const SizedBox(height: 4),
                    const _GroupNote(
                      'These carry over to your next session.',
                    ),
                  ],
                  const SizedBox(height: 8),
                  ...entry.value.map((t) => _settledOutcomeRow(
                        todo: t,
                        settlement: entry.key,
                        loggedMinutes: loggedMinutes[t.id] ?? 0,
                      )),
                  const SizedBox(height: 20),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptySettled extends StatelessWidget {
  const _EmptySettled();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline,
                size: 56, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text(
              'Nothing resolved yet today',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.grey[500],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tasks you finish or answer for during the day will appear here.',
              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupNote extends StatelessWidget {
  const _GroupNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
    );
  }
}

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({
    required this.settledCount,
    required this.completedCount,
    required this.totalEstimated,
    required this.totalActual,
  });

  /// Everything the user resolved today, across every group.
  final int settledCount;

  /// The Completion subset — the only one the time fold is meaningful over.
  final int completedCount;
  final int totalEstimated;
  final int totalActual;

  @override
  Widget build(BuildContext context) {
    final accuracy = totalEstimated > 0
        ? (totalActual / totalEstimated * 100).round()
        : null;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          // "Settled", not "Resolved": the step-1 card already spends
          // "resolution" on Disposition, and CONTEXT.md § Disposition lists
          // Resolution under _Avoid_.
          _StatChip(
            label: 'Settled',
            value: '$settledCount',
            color: const Color(0xFF1E3A5F),
          ),
          _StatChip(
            label: 'Done',
            value: '$completedCount',
            color: const Color(0xFF16A34A),
          ),
          _StatChip(
            label: 'Estimated',
            value: totalEstimated == 0 ? '—' : formatMinutesLabel(totalEstimated),
            color: const Color(0xFF2563EB),
          ),
          _StatChip(
            label: 'Actual',
            value: totalActual == 0 ? '—' : formatMinutesLabel(totalActual),
            color: const Color(0xFF7C3AED),
          ),
          if (accuracy != null)
            _StatChip(
              label: 'Accuracy',
              value: '$accuracy%',
              color: _accuracyColor(accuracy),
            ),
        ],
      ),
    );
  }

  Color _accuracyColor(int accuracy) {
    if (accuracy >= 80 && accuracy <= 120) return const Color(0xFF16A34A);
    if (accuracy >= 60 && accuracy <= 140) return const Color(0xFFF59E0B);
    return const Color(0xFFDC2626);
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip(
      {required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
            color: Color(0xFF9CA3AF),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}

Widget _settledOutcomeRow({
  required Todo todo,
  required SessionSettlement settlement,
  required int loggedMinutes,
}) {
  final estimated = todo.timeEstimate;
  final actual = loggedMinutes;
  final isDone = settlement == SessionSettlement.done;
  final icon = switch (settlement) {
    SessionSettlement.done => Icons.check_circle,
    SessionSettlement.next => Icons.east_rounded,
    SessionSettlement.waitingFor => Icons.hourglass_empty_rounded,
    SessionSettlement.someday => Icons.star_border,
  };
  return OutcomeRow(
    title: todo.title,
    framed: true,
    backgroundColor: isDone ? const Color(0xFFF0FDF4) : Colors.white,
    borderColor: isDone ? const Color(0xFFD1FAE5) : const Color(0xFFE5E7EB),
    leading: Icon(
      icon,
      size: 20,
      color: isDone ? const Color(0xFF16A34A) : const Color(0xFF6B7280),
    ),
    meta: estimated != null || actual > 0
        ? _TimeComparison(estimated: estimated, actual: actual)
        : null,
  );
}

class _TimeComparison extends StatelessWidget {
  const _TimeComparison({required this.estimated, required this.actual});

  final int? estimated;
  final int actual;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      children: [
        if (estimated != null)
          MetaChip(
            icon: Icons.timer_outlined,
            label: 'Est ${formatMinutesLabel(estimated!)}',
            color: const Color(0xFF2563EB),
          ),
        if (actual > 0)
          MetaChip(
            icon: Icons.history_toggle_off_outlined,
            label: 'Actual ${formatMinutesLabel(actual)}',
            color: _actualColor(estimated, actual),
          ),
      ],
    );
  }

  Color _actualColor(int? estimated, int actual) {
    if (estimated == null || estimated == 0) return const Color(0xFF7C3AED);
    final ratio = actual / estimated;
    if (ratio <= 1.2) return const Color(0xFF16A34A);
    if (ratio <= 1.5) return const Color(0xFFF59E0B);
    return const Color(0xFFDC2626);
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
        color: Color(0xFF9CA3AF),
      ),
    );
  }
}
