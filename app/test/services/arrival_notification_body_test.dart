import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/services/arrival_notifications.dart';

String _body({
  int outcomeCount = 0,
  List<String> outcomeTitles = const [],
  List<String> habitTitles = const [],
}) =>
    arrivalNotificationBody(
      outcomeCount: outcomeCount,
      outcomeTitles: outcomeTitles,
      habitTitles: habitTitles,
      random: Random(1),
    );

void main() {
  test('one Outcome is named', () {
    final body = _body(outcomeCount: 1, outcomeTitles: ['Buy screws']);
    expect(body, contains('One Outcome awaits'));
    expect(body, endsWith('Buy screws.'));
  });

  test('two Outcomes are both named', () {
    final body = _body(
        outcomeCount: 2, outcomeTitles: ['Buy screws', 'Return the drill']);
    expect(body, contains('Two Outcomes await'));
    expect(body, endsWith('Buy screws, Return the drill.'));
  });

  test('four Outcomes name three and count the rest', () {
    final body = _body(outcomeCount: 4, outcomeTitles: ['A', 'B', 'C']);
    expect(body, contains('Four Outcomes await'));
    expect(body, endsWith('A, B, C, and 1 more.'));
  });

  test('one Habit is named as a Habit', () {
    final body = _body(habitTitles: ['Workout']);
    expect(body, contains('One Habit awaits'));
    expect(body, endsWith('Workout.'));
  });

  test('a Habit and two Outcomes name the Habit first', () {
    final body = _body(
      habitTitles: ['Workout'],
      outcomeCount: 2,
      outcomeTitles: ['Buy screws', 'Return the drill'],
    );
    expect(body, contains('One Habit and two Outcomes await'));
    expect(body, endsWith('Workout, Buy screws, Return the drill.'));
  });

  test('two Habits and three Outcomes name three titles and count the rest',
      () {
    final body = _body(
      habitTitles: ['Workout', 'Read'],
      outcomeCount: 3,
      outcomeTitles: ['A', 'B', 'C'],
    );
    expect(body, contains('Two Habits and three Outcomes await'));
    expect(body, endsWith('Workout, Read, A, and 2 more.'));
  });

  test('every line of the pool opens a sentence with the count', () {
    for (var seed = 0; seed < 20; seed++) {
      final body = arrivalNotificationBody(
        outcomeCount: 1,
        outcomeTitles: ['Buy screws'],
        habitTitles: ['Workout'],
        random: Random(seed),
      );
      expect(body, contains('One Habit and one Outcome await'));
    }
  });

  test('payload round trips and rejects others', () {
    expect(arrivalPlaceIdFromPayload(arrivalNotificationPayload('p1')), 'p1');
    expect(arrivalPlaceIdFromPayload('focus'), isNull);
    expect(arrivalPlaceIdFromPayload('arrival:'), isNull);
  });
}
