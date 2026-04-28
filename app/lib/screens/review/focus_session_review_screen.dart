/// Session review screen — shown after the user taps "End Session" when
/// there are unfinished tasks.  The user assigns a disposition to each
/// pending task (Roll Over / Leave / Maybe) and then closes the session.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/focus_session_review_provider.dart';

class FocusSessionReviewScreen extends ConsumerStatefulWidget {
  const FocusSessionReviewScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<FocusSessionReviewScreen> createState() =>
      _FocusSessionReviewScreenState();
}

class _FocusSessionReviewScreenState
    extends ConsumerState<FocusSessionReviewScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(focusSessionReviewProvider.notifier)
          .initFromSession(widget.sessionId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final reviewState = ref.watch(focusSessionReviewProvider);
    final notifier = ref.read(focusSessionReviewProvider.notifier);

    final pending = reviewState.pendingTasks;
    final completed = reviewState.completedTasks;
    final reviewed = pending
        .where((t) => reviewState.dispositions.containsKey(t.id))
        .length;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- Header ----
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.nights_stay_outlined,
                          color: Color(0xFF2563EB)),
                      const SizedBox(width: 10),
                      const Text(
                        'Session Review',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A2E),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Wrap up your focus session',
                    style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                  ),
                  if (pending.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _ReviewProgressBar(
                        reviewed: reviewed, total: pending.length),
                  ],
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            // ---- Task lists ----
            Expanded(
              child: ListView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                children: [
                  if (completed.isNotEmpty) ...[
                    _SectionHeader(
                        label: 'COMPLETED', count: completed.length),
                    ...completed.map((t) => _CompletedTaskRow(todo: t)),
                    const SizedBox(height: 16),
                  ],
                  if (pending.isNotEmpty) ...[
                    _SectionHeader(
                        label: 'UNFINISHED', count: pending.length),
                    ...pending.map((t) => _PendingTaskRow(
                          todo: t,
                          selected: reviewState.dispositions[t.id],
                          onDisposition: (d) =>
                              notifier.setDisposition(t.id, d),
                        )),
                  ],
                  if (pending.isEmpty && completed.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'No tasks in this session.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[400]),
                      ),
                    ),
                  const SizedBox(height: 80),
                ],
              ),
            ),
            // ---- Close Session button ----
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: FilledButton(
                onPressed: reviewState.allPendingReviewed &&
                        !reviewState.isSubmitting
                    ? () => _closeSession(context, notifier)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold),
                ),
                child: reviewState.isSubmitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('Close Session'),
                          SizedBox(width: 6),
                          Icon(Icons.arrow_forward_rounded, size: 18),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _closeSession(
      BuildContext context, FocusSessionReviewNotifier notifier) async {
    await notifier.submitReview();
    if (!context.mounted) return;
    context.go('/inbox');
  }
}

// ---------------------------------------------------------------------------
// Progress bar
// ---------------------------------------------------------------------------

class _ReviewProgressBar extends StatelessWidget {
  const _ReviewProgressBar({required this.reviewed, required this.total});

  final int reviewed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final fraction = total == 0 ? 1.0 : reviewed / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 6,
            backgroundColor: const Color(0xFFE5E7EB),
            valueColor:
                const AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$reviewed / $total tasks reviewed',
          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Section header
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        '$label ($count)',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Color(0xFF6B7280),
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Completed task row (no chips)
// ---------------------------------------------------------------------------

class _CompletedTaskRow extends StatelessWidget {
  const _CompletedTaskRow({required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.check_circle_rounded,
              color: Color(0xFF16A34A), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              todo.title,
              style: const TextStyle(
                fontSize: 15,
                color: Color(0xFF9CA3AF),
                decoration: TextDecoration.lineThrough,
                decorationColor: Color(0xFF9CA3AF),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pending task row with three disposition chips
// ---------------------------------------------------------------------------

class _PendingTaskRow extends StatelessWidget {
  const _PendingTaskRow({
    required this.todo,
    required this.selected,
    required this.onDisposition,
  });

  final Todo todo;
  final ReviewDisposition? selected;
  final ValueChanged<ReviewDisposition> onDisposition;

  @override
  Widget build(BuildContext context) {
    final isReviewed = selected != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isReviewed
            ? const Color(0xFFF0F9FF)
            : const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isReviewed
              ? const Color(0xFFBAE6FD)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.radio_button_unchecked_rounded,
                  size: 16, color: Color(0xFF9CA3AF)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  todo.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _DispositionChip(
                label: 'Roll Over',
                value: ReviewDisposition.rollover,
                selected: selected,
                onTap: onDisposition,
              ),
              const SizedBox(width: 8),
              _DispositionChip(
                label: 'Leave',
                value: ReviewDisposition.leave,
                selected: selected,
                onTap: onDisposition,
              ),
              const SizedBox(width: 8),
              _DispositionChip(
                label: 'Maybe',
                value: ReviewDisposition.maybe,
                selected: selected,
                onTap: onDisposition,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Disposition chip
// ---------------------------------------------------------------------------

class _DispositionChip extends StatelessWidget {
  const _DispositionChip({
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final ReviewDisposition value;
  final ReviewDisposition? selected;
  final ValueChanged<ReviewDisposition> onTap;

  @override
  Widget build(BuildContext context) {
    final isSelected = selected == value;
    return GestureDetector(
      onTap: () => onTap(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color:
              isSelected ? const Color(0xFF2563EB) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF2563EB)
                : const Color(0xFFD1D5DB),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : const Color(0xFF374151),
          ),
        ),
      ),
    );
  }
}
