import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/models/todo.dart';

void main() {
  group('Todo', () {
    test('isActionable is false when done', () {
      final todo = Todo(
        id: 't1',
        title: 'Task',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        doneAt: '2024-01-01T00:00:00.000Z',
      );
      expect(todo.isActionable, isFalse);
    });

    test('isActionable is true when not done', () {
      final todo = Todo(
        id: 't2',
        title: 'Task',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(todo.isActionable, isTrue);
    });
  });
}
