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
      test('nextAction → waitingFor', () => expectValid(GtdState.nextAction, GtdState.waitingFor));

      test('waitingFor → nextAction', () => expectValid(GtdState.waitingFor, GtdState.nextAction));
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
      test('inProgress → waitingFor is rejected', () => expectInvalid(GtdState.inProgress, GtdState.waitingFor));
    });

    group('isValid', () {
      test('returns true for valid transitions', () {
        expect(GtdStateMachine.isValid(GtdState.nextAction, GtdState.inProgress), isTrue);
        expect(GtdStateMachine.isValid(GtdState.nextAction, GtdState.waitingFor), isTrue);
        expect(GtdStateMachine.isValid(GtdState.waitingFor, GtdState.nextAction), isTrue);
      });

      test('returns false for invalid transitions', () {
        expect(GtdStateMachine.isValid(GtdState.inProgress, GtdState.nextAction), isFalse);
        expect(GtdStateMachine.isValid(GtdState.inProgress, GtdState.waitingFor), isFalse);
      });
    });
  });
}
