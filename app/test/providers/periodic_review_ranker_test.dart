import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/providers/periodic_review_ranker.dart';

PeriodicReviewCandidate candidate(
  String id, {
  PeriodicReviewStepKind step = PeriodicReviewStepKind.next,
  DateTime? clarified,
  DateTime? created,
}) => PeriodicReviewCandidate(
  step: step,
  id: id,
  lastClarifiedAt: clarified,
  createdAt: created ?? DateTime.utc(2026),
);

void main() {
  const ranker = FreshnessPeriodicReviewRanker();

  test('Inbox first, then every step interleaves by least recent clarification', () async {
    final day = DateTime.utc(2026, 3, 10);
    final inputs = [
      candidate('someday-oldest', step: PeriodicReviewStepKind.someday,
          clarified: day.subtract(const Duration(days: 80))),
      candidate('next-old', clarified: day.subtract(const Duration(days: 60))),
      candidate('waiting-recent', step: PeriodicReviewStepKind.waitingFor,
          clarified: day.subtract(const Duration(days: 1))),
      candidate('next-never', created: day),
      candidate('capture-late', step: PeriodicReviewStepKind.inbox,
          created: day.add(const Duration(days: 5))),
      candidate('capture-early', step: PeriodicReviewStepKind.inbox, created: day),
      candidate('someday-recent', step: PeriodicReviewStepKind.someday, clarified: day),
    ];
    const expected = ['capture-early', 'capture-late', 'next-never',
      'someday-oldest', 'next-old', 'waiting-recent', 'someday-recent'];
    for (var seed = 0; seed < 10; seed++) {
      final shuffled = [...inputs]..shuffle(Random(seed));
      expect((await ranker.rank(shuffled)).map((c) => c.id), expected);
    }
  });

  test('ties fall to creation, id, then step order', () async {
    final date = DateTime.utc(2026);
    final inputs = [
      candidate('x', step: PeriodicReviewStepKind.someday, clarified: date),
      candidate('x', step: PeriodicReviewStepKind.waitingFor, clarified: date),
      candidate('b', clarified: date),
      candidate('a', clarified: date, created: date.add(const Duration(days: 1))),
    ];
    final ranked = await ranker.rank(inputs);
    expect(ranked.map((c) => (c.step, c.id)), [
      (PeriodicReviewStepKind.next, 'b'),
      (PeriodicReviewStepKind.next, 'a'),
      (PeriodicReviewStepKind.waitingFor, 'x'),
      (PeriodicReviewStepKind.someday, 'x'),
    ]);
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
