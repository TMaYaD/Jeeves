import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/screens/planning/steps/task_review_step.dart';

Todo _todo({String? nextActionText}) {
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
    nextActionText: nextActionText,
  );
}

void main() {
  group('hintFor — actionless detection (#278)', () {
    test('null next_action_text → noNextAction', () {
      expect(hintFor(_todo()), ReclarifyHint.noNextAction);
    });

    test('whitespace-only next_action_text → noNextAction', () {
      expect(
        hintFor(_todo(nextActionText: '   ')),
        ReclarifyHint.noNextAction,
        reason:
            'TodoDao._needsReviewWhere matches both NULL and TRIM("") = "", so '
            'a whitespace-only value lands in the queue. hintFor must agree.',
      );
    });

    test('tabs and newlines → noNextAction', () {
      expect(hintFor(_todo(nextActionText: '\t\n ')), ReclarifyHint.noNextAction);
    });

    test('non-empty text → updatedSinceClarified', () {
      expect(
        hintFor(_todo(nextActionText: 'Call Trixy')),
        ReclarifyHint.updatedSinceClarified,
      );
    });

    test('text with leading/trailing whitespace → updatedSinceClarified', () {
      expect(
        hintFor(_todo(nextActionText: '  Call Trixy  ')),
        ReclarifyHint.updatedSinceClarified,
      );
    });
  });
}
