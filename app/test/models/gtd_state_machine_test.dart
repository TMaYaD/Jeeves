import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/gtd_state_machine.dart';
import 'package:jeeves/models/todo.dart';

void main() {
  // GtdStateMachine.allowedTransitions is now empty — in_progress was retired
  // in migration 0019 and is tracked via focus_sessions.current_task_id.
  // PR J will remove this file entirely.
  group('GtdStateMachine', () {
    test('validate always throws: no transitions remain', () {
      expect(
        () => GtdStateMachine.validate(GtdState.nextAction, GtdState.nextAction),
        throwsA(isA<InvalidStateTransitionException>()),
      );
    });

    test('isValid always returns false', () {
      expect(
        GtdStateMachine.isValid(GtdState.nextAction, GtdState.nextAction),
        isFalse,
      );
    });
  });
}
