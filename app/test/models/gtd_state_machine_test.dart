import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/gtd_state_machine.dart';
import 'package:jeeves/models/todo.dart';

void main() {
  group('GtdStateMachine', () {
    group('valid transitions', () {
      void expectValid(GtdState from, GtdState to) {
        expect(
          () => GtdStateMachine.validate(from, to),
          returnsNormally,
          reason: 'Expected ${from.value} → ${to.value} to be valid',
        );
      }

      test('nextAction → inProgress', () => expectValid(GtdState.nextAction, GtdState.inProgress));
    });

    group('invalid transitions', () {
      void expectInvalid(GtdState from, GtdState to) {
        expect(
          () => GtdStateMachine.validate(from, to),
          throwsA(isA<InvalidStateTransitionException>()),
          reason: 'Expected ${from.value} → ${to.value} to be invalid',
        );
      }

      // inProgress has no valid FSM exits (completion is via markDone; PR I retires it)
      test('inProgress → nextAction is rejected', () => expectInvalid(GtdState.inProgress, GtdState.nextAction));
    });

    group('isValid', () {
      test('returns true for valid transitions', () {
        expect(GtdStateMachine.isValid(GtdState.nextAction, GtdState.inProgress), isTrue);
      });

      test('returns false for invalid transitions', () {
        expect(GtdStateMachine.isValid(GtdState.inProgress, GtdState.nextAction), isFalse);
      });
    });
  });
}
