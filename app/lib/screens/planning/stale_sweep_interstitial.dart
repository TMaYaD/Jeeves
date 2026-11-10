import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../database/daos/focus_session_dao.dart' show StaleOutcome;
import '../../providers/stale_sweep_provider.dart';
import '../../widgets/ceremony/ceremony_pop_scope.dart';

/// Shown before the Daily Planning wizard while any Outcome is Stale (CONTEXT.md
/// § Engagement). Each Stale Outcome must be moved to Someday/Maybe or Trashed;
/// there is no skip. The only way out without deciding is leaving for Now, which
/// abandons the performance. The parent screen drops this once the list is empty.
class StaleSweepInterstitial extends ConsumerWidget {
  const StaleSweepInterstitial({super.key, required this.staleOutcomes});

  final List<StaleOutcome> staleOutcomes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sweep = ref.read(staleSweepProvider);
    return CeremonyPopScope(
      onBack: null,
      child: Scaffold(
        key: const Key('stale_sweep_interstitial'),
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Stale Outcomes',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A2E),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your recent sessions passed these over. Decide for each: '
                  'park it in Someday/Maybe, or Trash it.',
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.5,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: ListView.separated(
                    itemCount: staleOutcomes.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final stale = staleOutcomes[index];
                      return _StaleOutcomeCard(
                        stale: stale,
                        onMoveToSomedayMaybe: () =>
                            sweep.moveToSomedayMaybe(stale.outcome.id),
                        onTrash: () => sweep.trash(stale.outcome.id),
                      );
                    },
                  ),
                ),
                TextButton(
                  key: const Key('stale_sweep_not_now'),
                  onPressed: () => context.go('/focus'),
                  child: const Text('Not now'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StaleOutcomeCard extends StatelessWidget {
  const _StaleOutcomeCard({
    required this.stale,
    required this.onMoveToSomedayMaybe,
    required this.onTrash,
  });

  final StaleOutcome stale;
  final VoidCallback onMoveToSomedayMaybe;
  final VoidCallback onTrash;

  @override
  Widget build(BuildContext context) {
    final id = stale.outcome.id;
    return Card(
      key: Key('stale_sweep_card_$id'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              stale.outcome.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Passed over in ${stale.passedOverSessionCount} sessions',
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: Key('stale_sweep_maybe_$id'),
                    onPressed: onMoveToSomedayMaybe,
                    child: const Text('Move to Someday/Maybe'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    key: Key('stale_sweep_trash_$id'),
                    onPressed: onTrash,
                    child: const Text('Trash'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
