import 'package:flutter_riverpod/flutter_riverpod.dart';

const kWeeklyReviewMinutesPerItem = 2;

int weeklyReviewItemBudget(int minutes) => minutes ~/ kWeeklyReviewMinutesPerItem;

List<int> weeklyReviewBudgetOptions(int itemCount) => [
  for (final minutes in const [15, 30, 60])
    if (minutes < itemCount * kWeeklyReviewMinutesPerItem) minutes,
];

enum PeriodicReviewStepKind { inbox, waitingFor, next, someday }

class PeriodicReviewCandidate {
  const PeriodicReviewCandidate({
    required this.step,
    required this.id,
    required this.lastClarifiedAt,
    required this.createdAt,
  });

  final PeriodicReviewStepKind step;
  final String id;
  final DateTime? lastClarifiedAt;
  final DateTime createdAt;
}

abstract interface class PeriodicReviewRanker {
  Future<List<PeriodicReviewCandidate>> rank(List<PeriodicReviewCandidate> candidates);
}

final periodicReviewRankerProvider = Provider<PeriodicReviewRanker>(
  (ref) => const FreshnessPeriodicReviewRanker(),
);

/// Inbox first, then least recently clarified; see CEREMONIES.md, Weekly Review sessions.
class FreshnessPeriodicReviewRanker implements PeriodicReviewRanker {
  const FreshnessPeriodicReviewRanker();

  @override
  Future<List<PeriodicReviewCandidate>> rank(List<PeriodicReviewCandidate> candidates) async {
    return [...candidates]..sort((a, b) {
      final aIsInbox = a.step == PeriodicReviewStepKind.inbox;
      final bIsInbox = b.step == PeriodicReviewStepKind.inbox;
      if (aIsInbox != bIsInbox) return aIsInbox ? -1 : 1;
      final aClarified = a.lastClarifiedAt;
      final bClarified = b.lastClarifiedAt;
      var order = aClarified == null
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
