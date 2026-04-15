/// Step 1 of the daily planning ritual: review Next Actions.
///
/// Displays unreviewed next-action tasks as swipeable cards.
/// - Swipe right or tap checkmark → select for today.
/// - Swipe left or tap dash → skip for today.
/// - Tap clock-x → defer to Someday/Maybe.
/// An undo [SnackBar] appears for 3 seconds after each swipe action.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/daily_planning_provider.dart';

class NextActionsReviewStep extends ConsumerWidget {
  const NextActionsReviewStep({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(nextActionsForPlanningProvider);

    return asyncItems.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (items) {
        if (items.isEmpty) {
          return const _EmptyNextActions();
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: items.length,
          separatorBuilder: (context, i) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _ReviewCard(
            todo: items[i],
            onSelect: () =>
                _handleAction(context, ref, items[i], _Action.select),
            onSkip: () =>
                _handleAction(context, ref, items[i], _Action.skip),
            onDefer: () => _handleDefer(context, ref, items[i]),
          ),
        );
      },
    );
  }

  Future<void> _handleAction(
      BuildContext context, WidgetRef ref, Todo todo, _Action action) async {
    final notifier = ref.read(dailyPlanningProvider.notifier);
    try {
      if (action == _Action.select) {
        await notifier.selectTask(todo.id);
      } else {
        await notifier.skipTask(todo.id);
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
      return;
    }

    if (!context.mounted) return;
    final label = action == _Action.select ? 'Selected' : 'Skipped';
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label: ${todo.title}'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            try {
              await notifier.undoTaskReview(todo.id);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).clearSnackBars();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Undo failed: $e')),
                );
              }
            }
          },
        ),
      ),
    );
  }

  Future<void> _handleDefer(
      BuildContext context, WidgetRef ref, Todo todo) async {
    final notifier = ref.read(dailyPlanningProvider.notifier);
    try {
      await notifier.deferTask(todo.id);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
      return;
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deferred to Someday/Maybe: ${todo.title}'),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

enum _Action { select, skip }

// ---------------------------------------------------------------------------
// Swipeable review card
// ---------------------------------------------------------------------------

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.todo,
    required this.onSelect,
    required this.onSkip,
    required this.onDefer,
  });

  final Todo todo;
  final VoidCallback onSelect;
  final VoidCallback onSkip;
  final VoidCallback onDefer;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey(todo.id),
      background: _swipeBackground(
        alignment: Alignment.centerLeft,
        color: const Color(0xFF16A34A),
        icon: Icons.check,
        label: 'Select',
      ),
      secondaryBackground: _swipeBackground(
        alignment: Alignment.centerRight,
        color: const Color(0xFF6B7280),
        icon: Icons.remove,
        label: 'Skip',
      ),
      onDismissed: (direction) {
        if (direction == DismissDirection.startToEnd) {
          onSelect();
        } else {
          onSkip();
        }
      },
      child: Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Expanded(child: _TodoInfo(todo: todo)),
              const SizedBox(width: 8),
              _ActionButtons(
                onSelect: onSelect,
                onSkip: onSkip,
                onDefer: onDefer,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _swipeBackground({
    required AlignmentGeometry alignment,
    required Color color,
    required IconData icon,
    required String label,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 24),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _TodoInfo extends StatelessWidget {
  const _TodoInfo({required this.todo});

  final Todo todo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          todo.title,
          style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: Color(0xFF1A1A2E)),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 6,
          children: [
            if (todo.timeEstimate != null)
              _Chip(
                icon: Icons.timer_outlined,
                label: '${todo.timeEstimate}m',
                color: const Color(0xFF2563EB),
              ),
            if (todo.energyLevel != null)
              _Chip(
                icon: Icons.bolt_outlined,
                label: _energyLabel(todo.energyLevel!),
                color: const Color(0xFF7C3AED),
              ),
          ],
        ),
      ],
    );
  }

  String _energyLabel(String level) => switch (level) {
        'low' => 'Low',
        'medium' => 'Medium',
        'high' => 'High',
        _ => level,
      };
}

class _Chip extends StatelessWidget {
  const _Chip(
      {required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 2),
        Text(label,
            style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
      ],
    );
  }
}

class _ActionButtons extends StatelessWidget {
  const _ActionButtons(
      {required this.onSelect, required this.onSkip, required this.onDefer});

  final VoidCallback onSelect;
  final VoidCallback onSkip;
  final VoidCallback onDefer;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconBtn(
            icon: Icons.check_circle_outline,
            color: const Color(0xFF16A34A),
            tooltip: 'Select for today',
            onTap: onSelect),
        _IconBtn(
            icon: Icons.remove_circle_outline,
            color: const Color(0xFF6B7280),
            tooltip: 'Skip',
            onTap: onSkip),
        _IconBtn(
            icon: Icons.schedule_send_outlined,
            color: const Color(0xFFF59E0B),
            tooltip: 'Defer to Someday',
            onTap: onDefer),
      ],
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn(
      {required this.icon,
      required this.color,
      required this.tooltip,
      required this.onTap});

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: color, size: 22),
      tooltip: tooltip,
      onPressed: onTap,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
    );
  }
}

class _EmptyNextActions extends StatelessWidget {
  const _EmptyNextActions();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline,
              size: 56, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'All caught up!',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600]),
          ),
          const SizedBox(height: 6),
          Text(
            'No next actions to review.',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap Next to continue.',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}
