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

      test('inbox → nextAction', () => expectValid(GtdState.inbox, GtdState.nextAction));
      test('inbox → waitingFor', () => expectValid(GtdState.inbox, GtdState.waitingFor));
      test('inbox → somedayMaybe', () => expectValid(GtdState.inbox, GtdState.somedayMaybe));
      test('inbox → done', () => expectValid(GtdState.inbox, GtdState.done));

      test('nextAction → inProgress', () => expectValid(GtdState.nextAction, GtdState.inProgress));
      test('nextAction → waitingFor', () => expectValid(GtdState.nextAction, GtdState.waitingFor));
      test('nextAction → somedayMaybe', () => expectValid(GtdState.nextAction, GtdState.somedayMaybe));
      test('nextAction → done', () => expectValid(GtdState.nextAction, GtdState.done));

      test('waitingFor → nextAction', () => expectValid(GtdState.waitingFor, GtdState.nextAction));
      test('waitingFor → somedayMaybe', () => expectValid(GtdState.waitingFor, GtdState.somedayMaybe));
      test('waitingFor → done', () => expectValid(GtdState.waitingFor, GtdState.done));

      test('inProgress → done', () => expectValid(GtdState.inProgress, GtdState.done));

      test('somedayMaybe → nextAction', () => expectValid(GtdState.somedayMaybe, GtdState.nextAction));
      test('somedayMaybe → done', () => expectValid(GtdState.somedayMaybe, GtdState.done));
    });

    group('invalid transitions', () {
      void expectInvalid(GtdState from, GtdState to) {
        expect(
          () => GtdStateMachine.validate(from, to),
          throwsA(isA<InvalidStateTransitionException>()),
          reason: 'Expected ${from.value} → ${to.value} to be invalid',
        );
      }

      // Key boundary: inbox cannot go directly to inProgress
      test('inbox → inProgress is rejected', () => expectInvalid(GtdState.inbox, GtdState.inProgress));

      // inProgress cannot go to somedayMaybe (deferred was the bridge; now removed)
      test('inProgress → somedayMaybe is rejected', () => expectInvalid(GtdState.inProgress, GtdState.somedayMaybe));

      // done is terminal
      test('done → nextAction is rejected', () => expectInvalid(GtdState.done, GtdState.nextAction));
      test('done → inbox is rejected', () => expectInvalid(GtdState.done, GtdState.inbox));

      // inProgress cannot go back to inbox or nextAction
      test('inProgress → inbox is rejected', () => expectInvalid(GtdState.inProgress, GtdState.inbox));
      test('inProgress → nextAction is rejected', () => expectInvalid(GtdState.inProgress, GtdState.nextAction));
    });

    group('isValid', () {
      test('returns true for valid transitions', () {
        expect(GtdStateMachine.isValid(GtdState.inbox, GtdState.nextAction), isTrue);
        expect(GtdStateMachine.isValid(GtdState.nextAction, GtdState.inProgress), isTrue);
      });

      test('returns false for invalid transitions', () {
        expect(GtdStateMachine.isValid(GtdState.inbox, GtdState.inProgress), isFalse);
        expect(GtdStateMachine.isValid(GtdState.done, GtdState.inbox), isFalse);
      });
    });
  });
}
