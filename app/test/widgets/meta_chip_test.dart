import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/widgets/meta_chip.dart';

void main() {
  group('formatMinutesLabel', () {
    test('minutes only below an hour', () {
      expect(formatMinutesLabel(0), '0m');
      expect(formatMinutesLabel(45), '45m');
    });

    test('whole hours drop the minutes', () {
      expect(formatMinutesLabel(60), '1h');
      expect(formatMinutesLabel(120), '2h');
    });

    test('hours and minutes together', () {
      expect(formatMinutesLabel(210), '3h 30m');
    });
  });
}
