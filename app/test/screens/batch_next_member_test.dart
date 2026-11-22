import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart'
    show SessionSettlement;
import 'package:jeeves/screens/active_focus_screen.dart';

Todo _todo(String id, {String? doneAt}) => Todo(
      id: id,
      title: 'Task $id',
      createdAt: DateTime.now(),
      doneAt: doneAt,
      intent: 'next',
      userId: 'local',
    );

DateTime _at(int minute) => DateTime.utc(2026, 11, 16, 9, minute);

void main() {
  const batch = (batchId: 'b1', declined: false);

  test('the next member follows the batch in start-time order', () {
    // The Plan lists c before b, but b starts first.
    expect(
      batchNextMemberId(
        completedTodoId: 'a',
        batchState: const {'a': batch, 'b': batch, 'c': batch},
        pinnedStarts: {'a': _at(0), 'b': _at(10), 'c': _at(20)},
        sessionTasks: [_todo('a'), _todo('c'), _todo('b')],
        settlements: const {},
      ),
      'b',
    );
  });

  test('a done or Settled member is skipped', () {
    expect(
      batchNextMemberId(
        completedTodoId: 'a',
        batchState: const {'a': batch, 'b': batch, 'c': batch, 'd': batch},
        pinnedStarts: {'a': _at(0), 'b': _at(10), 'c': _at(20), 'd': _at(30)},
        sessionTasks: [
          _todo('a'),
          _todo('b', doneAt: '2026-11-16T09:12:00.000Z'),
          _todo('c'),
          _todo('d'),
        ],
        settlements: const {'c': SessionSettlement.next},
      ),
      'd',
    );
  });

  test('the last member has no next member', () {
    expect(
      batchNextMemberId(
        completedTodoId: 'b',
        batchState: const {'a': batch, 'b': batch},
        pinnedStarts: {'a': _at(0), 'b': _at(10)},
        sessionTasks: [_todo('a', doneAt: '2026-11-16T09:05:00.000Z'), _todo('b')],
        settlements: const {},
      ),
      isNull,
    );
  });

  test('an Outcome outside any batch, or in another batch, has none', () {
    const other = (batchId: 'b2', declined: false);
    expect(
      batchNextMemberId(
        completedTodoId: 'a',
        batchState: const {'b': batch},
        pinnedStarts: const {},
        sessionTasks: [_todo('a'), _todo('b')],
        settlements: const {},
      ),
      isNull,
    );
    expect(
      batchNextMemberId(
        completedTodoId: 'a',
        batchState: const {'a': batch, 'b': other},
        pinnedStarts: const {},
        sessionTasks: [_todo('a'), _todo('b')],
        settlements: const {},
      ),
      isNull,
    );
  });
}
