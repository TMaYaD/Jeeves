import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/screens/habits/habit_copy.dart';

void main() {
  group('habitAmountText', () {
    test('keeps small fractions and drops float noise', () {
      expect(habitAmountText(0.04), '0.04');
      expect(habitAmountText(0.7 + 0.1), '0.8');
      expect(habitAmountText(2.5), '2.5');
    });

    test('groups thousands and shows whole numbers plain', () {
      expect(habitAmountText(8000), '8,000');
      expect(habitAmountText(3), '3');
    });
  });

  group('habitPlaceLine', () {
    test('puts the Place in front of the Habit\'s own line', () {
      expect(
        habitPlaceLine(placeName: 'Home', line: 'Not yet'),
        'Home · Not yet',
      );
    });

    test('shows the Place alone when the Habit has nothing else to say', () {
      expect(habitPlaceLine(placeName: 'Home', line: ''), 'Home');
      expect(habitPlaceLine(placeName: 'Home', line: null), 'Home');
    });

    test('leaves the line alone when the Habit has no Place', () {
      expect(habitPlaceLine(placeName: null, line: 'Not yet'), 'Not yet');
      expect(habitPlaceLine(placeName: null, line: null), '');
      expect(habitPlaceLine(placeName: '', line: 'Not yet'), 'Not yet');
    });
  });
}
