import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/screens/planning/steps/task_review_step.dart';

Todo _todo({
  DateTime? lastNextActionCompletionAt,
  DateTime? lastClarifiedAt,
}) {
  final now = DateTime.now();
  return Todo(
    id: 't',
    title: 'task',
    intent: 'next',
    clarified: true,
    createdAt: now,
    updatedAt: now,
    userId: 'u',
    timeSpentMinutes: 0,
    lastNextActionCompletionAt: lastNextActionCompletionAt,
    lastClarifiedAt: lastClarifiedAt,
  );
}

void main() {
  group('hintFor — actionless detection (#278)', () {
    test('no current Action → noNextAction', () {
      expect(
        hintFor(_todo(), hasPersonTag: false, isStale: false),
        ReclarifyHint.noNextAction,
      );
    });

    test('whitespace-only Action text → noNextAction', () {
      expect(
        hintFor(_todo(),
            hasPersonTag: false, isStale: false, currentActionText: '   '),
        ReclarifyHint.noNextAction,
        reason:
            'hintFor reads the same evidence as TodoDao._needsReviewWhere — '
            'the absence of a current Action. A whitespace-only phrase is not '
            'representable as an Action, so it must read as Actionless.',
      );
    });

    test('tabs and newlines → noNextAction', () {
      expect(
        hintFor(_todo(),
            hasPersonTag: false, isStale: false, currentActionText: '\t\n '),
        ReclarifyHint.noNextAction,
      );
    });

    test('non-empty text → updatedSinceClarified', () {
      expect(
        hintFor(_todo(),
            hasPersonTag: false, isStale: true, currentActionText: 'Call Trixy'),
        ReclarifyHint.updatedSinceClarified,
      );
    });

    test('text with leading/trailing whitespace → updatedSinceClarified', () {
      expect(
        hintFor(_todo(),
            hasPersonTag: false, isStale: true, currentActionText: '  Call Trixy  '),
        ReclarifyHint.updatedSinceClarified,
      );
    });
  });

  group('hintFor — staleWaitingFor branch (#289)', () {
    test(
        'stale + has person tag + has a current Action → staleWaitingFor (wins '
        'over updatedSinceClarified)', () {
      expect(
        hintFor(
          _todo(),
          hasPersonTag: true,
          isStale: true,
          currentActionText: 'Email Trixy',
        ),
        ReclarifyHint.staleWaitingFor,
      );
    });

    test(
        'stale + has person tag + no current Action → staleWaitingFor (wins '
        'over noNextAction)', () {
      expect(
        hintFor(
          _todo(),
          hasPersonTag: true,
          isStale: true,
        ),
        ReclarifyHint.staleWaitingFor,
      );
    });

    test('not stale + has person tag → falls through (helper must be total)',
        () {
      // Predicate prevents this combo from reaching hintFor in practice; the
      // helper still has to return something coherent.
      expect(
        hintFor(_todo(),
            hasPersonTag: true, isStale: false, currentActionText: 'X'),
        ReclarifyHint.updatedSinceClarified,
      );
      expect(
        hintFor(_todo(), hasPersonTag: true, isStale: false),
        ReclarifyHint.noNextAction,
      );
    });

    test('stale + no person tag → updatedSinceClarified (unchanged)', () {
      expect(
        hintFor(
          _todo(),
          hasPersonTag: false,
          isStale: true,
          currentActionText: 'Draft email',
        ),
        ReclarifyHint.updatedSinceClarified,
      );
    });
  });

  group('isStaleReclarification', () {
    test('null lastNextActionCompletionAt → not stale', () {
      expect(isStaleReclarification(_todo()), isFalse);
    });

    test(
        'lastNextActionCompletionAt set, lastClarifiedAt null → stale',
        () {
      expect(
        isStaleReclarification(_todo(
          lastNextActionCompletionAt: DateTime.now(),
        )),
        isTrue,
      );
    });

    test('clarified before completion → stale', () {
      final now = DateTime.now();
      expect(
        isStaleReclarification(_todo(
          lastClarifiedAt: now.subtract(const Duration(hours: 2)),
          lastNextActionCompletionAt:
              now.subtract(const Duration(hours: 1)),
        )),
        isTrue,
      );
    });

    test('clarified after completion → not stale', () {
      final now = DateTime.now();
      expect(
        isStaleReclarification(_todo(
          lastClarifiedAt: now,
          lastNextActionCompletionAt:
              now.subtract(const Duration(hours: 1)),
        )),
        isFalse,
      );
    });
  });
}
