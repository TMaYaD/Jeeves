import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/periodic_review_ranker.dart';

PeriodicReviewCandidate candidate(
  String id, {
  PeriodicReviewStepKind step = PeriodicReviewStepKind.next,
  bool planless = false,
  bool stale = false,
  bool actionless = false,
  DateTime? clarified,
  DateTime? created,
}) => PeriodicReviewCandidate(
  step: step,
  id: id,
  isPlanless: planless,
  isStale: stale,
  isActionless: actionless,
  lastClarifiedAt: clarified,
  createdAt: created ?? DateTime.utc(2026),
);

void main() {
  const ranker = FreshnessPeriodicReviewRanker();

  test('tiers, freshness and stable identity produce deterministic priority', () async {
    final inputs = [
      candidate('remaining'),
      candidate('waiting', step: PeriodicReviewStepKind.waitingFor),
      candidate('actionless', actionless: true),
      candidate('stale', stale: true),
      candidate('planless', planless: true, stale: true, actionless: true),
      candidate('capture', step: PeriodicReviewStepKind.inbox),
      candidate('someday', step: PeriodicReviewStepKind.someday,
          planless: true, stale: true, actionless: true),
    ];
    const expected = ['capture', 'planless', 'stale', 'actionless',
      'waiting', 'remaining', 'someday'];
    for (var seed = 0; seed < 10; seed++) {
      final shuffled = [...inputs]..shuffle(Random(seed));
      expect((await ranker.rank(shuffled)).map((c) => c.id), expected);
    }
  });

  test('null clarification first, then clarification, creation and id', () async {
    final date = DateTime.utc(2026);
    final inputs = [
      candidate('z', clarified: date),
      candidate('a', clarified: date),
      candidate('older-created', clarified: date, created: date.subtract(const Duration(days: 1))),
      candidate('older-clarified', clarified: date.subtract(const Duration(days: 1))),
      candidate('never'),
    ];
    expect((await ranker.rank(inputs)).map((c) => c.id),
      ['never', 'older-clarified', 'older-created', 'a', 'z']);
  });

  test('time options appear only below the full estimate', () {
    expect(weeklyReviewBudgetOptions(0), isEmpty);
    expect(weeklyReviewBudgetOptions(7), isEmpty);
    expect(weeklyReviewBudgetOptions(8), [15]);
    expect(weeklyReviewBudgetOptions(15), [15]);
    expect(weeklyReviewBudgetOptions(16), [15, 30]);
    expect(weeklyReviewBudgetOptions(30), [15, 30]);
    expect(weeklyReviewBudgetOptions(31), [15, 30, 60]);
    expect(weeklyReviewItemBudget(15), 7);
    expect(weeklyReviewItemBudget(30), 15);
    expect(weeklyReviewItemBudget(60), 30);
  });
}
