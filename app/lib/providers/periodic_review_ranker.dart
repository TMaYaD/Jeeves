import 'package:flutter_riverpod/flutter_riverpod.dart';

const kWeeklyReviewMinutesPerItem = 2;

int weeklyReviewItemBudget(int minutes) => minutes ~/ kWeeklyReviewMinutesPerItem;

List<int> weeklyReviewBudgetOptions(int itemCount) => [
  for (final minutes in const [15, 30, 60])
    if (minutes < itemCount * kWeeklyReviewMinutesPerItem) minutes,
];

enum PeriodicReviewStepKind { inbox, bypassed, waitingFor, next, someday }

class PeriodicReviewCandidate {
  const PeriodicReviewCandidate({
    required this.step,
    required this.id,
    required this.isPlanless,
    required this.isStale,
    required this.isActionless,
    required this.lastClarifiedAt,
    required this.createdAt,
  });

  final PeriodicReviewStepKind step;
  final String id;
  final bool isPlanless;
  final bool isStale;
  final bool isActionless;
  final DateTime? lastClarifiedAt;
  final DateTime createdAt;
}

abstract interface class PeriodicReviewRanker {
  Future<List<PeriodicReviewCandidate>> rank(List<PeriodicReviewCandidate> candidates);
}

final periodicReviewRankerProvider = Provider<PeriodicReviewRanker>(
  (ref) => const FreshnessPeriodicReviewRanker(),
);

/// First matching tier wins; see CEREMONIES.md, Weekly Review sessions.
class FreshnessPeriodicReviewRanker implements PeriodicReviewRanker {
  const FreshnessPeriodicReviewRanker();

  int _tier(PeriodicReviewCandidate candidate) {
    if (candidate.step == PeriodicReviewStepKind.inbox) return 0;
    if (candidate.step == PeriodicReviewStepKind.bypassed) return 1;
    if (candidate.step != PeriodicReviewStepKind.someday) {
      if (candidate.isPlanless) return 2;
      if (candidate.isStale) return 3;
      if (candidate.isActionless) return 4;
      if (candidate.step == PeriodicReviewStepKind.waitingFor) return 5;
    }
    return 6;
  }

  @override
  Future<List<PeriodicReviewCandidate>> rank(List<PeriodicReviewCandidate> candidates) async {
    return [...candidates]..sort((a, b) {
      var order = _tier(a).compareTo(_tier(b));
      if (order != 0) return order;
      final aClarified = a.lastClarifiedAt;
      final bClarified = b.lastClarifiedAt;
      order = aClarified == null
          ? (bClarified == null ? 0 : -1)
          : (bClarified == null ? 1 : aClarified.compareTo(bClarified));
      if (order != 0) return order;
      order = a.createdAt.compareTo(b.createdAt);
      if (order != 0) return order;
      order = a.id.compareTo(b.id);
      return order != 0 ? order : a.step.index.compareTo(b.step.index);
    });
  }
}
