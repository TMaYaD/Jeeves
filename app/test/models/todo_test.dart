import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/todo.dart';

void main() {
  group('GtdState', () {
    test('fromString defensive: scheduled maps to nextAction', () {
      expect(GtdState.fromString('scheduled'), GtdState.nextAction);
    });
  });
}
