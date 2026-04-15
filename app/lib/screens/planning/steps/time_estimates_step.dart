/// Step 3 of the daily planning ritual: set time estimates.
///
/// Lists selected tasks that are missing a time estimate. Each item shows a
/// segmented chip picker with standard durations. Once the user picks a value
/// the row collapses and is removed from the list.
///
/// The Next button in the parent becomes enabled when this list is empty.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/daily_planning_provider.dart';

class TimeEstimatesStep extends ConsumerWidget {
  const TimeEstimatesStep({super.key});

  static const _options = [5, 10, 15, 30, 45, 60, 90, 120];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncItems = ref.watch(selectedTasksMissingEstimatesProvider);

    return asyncItems.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(child: Text('Error: $err')),
      data: (items) {
        if (items.isEmpty) {
          return const _AllEstimatesSet();
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: items.length,
          separatorBuilder: (context, i) => const SizedBox(height: 12),
          itemBuilder: (context, i) => _EstimateCard(
            todo: items[i],
            options: _options,
            onPick: (minutes) => ref
                .read(dailyPlanningProvider.notifier)
                .setTimeEstimate(items[i].id, minutes),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Estimate card
// ---------------------------------------------------------------------------

class _EstimateCard extends StatelessWidget {
  const _EstimateCard(
      {required this.todo,
      required this.options,
      required this.onPick});

  final Todo todo;
  final List<int> options;
  final void Function(int minutes) onPick;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              todo.title,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF1A1A2E)),
            ),
            const SizedBox(height: 10),
            Text(
              'How long will this take?',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: options
                  .map((m) => _EstimateChip(
                        label: m < 60 ? '${m}m' : '${m ~/ 60}h',
                        onTap: () => onPick(m),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _EstimateChip extends StatelessWidget {
  const _EstimateChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFF2563EB)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF2563EB),
              fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _AllEstimatesSet extends StatelessWidget {
  const _AllEstimatesSet();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer_outlined, size: 56, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'All estimates set!',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600]),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap Next to see your plan.',
            style: TextStyle(fontSize: 14, color: Colors.grey[400]),
          ),
        ],
      ),
    );
  }
}
