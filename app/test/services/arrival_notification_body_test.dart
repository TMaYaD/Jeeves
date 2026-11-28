import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/services/arrival_notifications.dart';

void main() {
  test('one Outcome is named', () {
    final body = arrivalNotificationBody(
        dueCount: 1, dueTitles: ['Buy screws'], random: Random(1));
    expect(body, contains('One Outcome awaits'));
    expect(body, endsWith('Buy screws.'));
  });

  test('two Outcomes are both named', () {
    final body = arrivalNotificationBody(
        dueCount: 2,
        dueTitles: ['Buy screws', 'Return the drill'],
        random: Random(1));
    expect(body, contains('Two Outcomes await'));
    expect(body, endsWith('Buy screws, Return the drill.'));
  });

  test('four Outcomes name three and count the rest', () {
    final body = arrivalNotificationBody(
        dueCount: 4, dueTitles: ['A', 'B', 'C'], random: Random(1));
    expect(body, contains('Four Outcomes await'));
    expect(body, endsWith('A, B, C, and 1 more.'));
  });

  test('payload round trips and rejects others', () {
    expect(arrivalPlaceIdFromPayload(arrivalNotificationPayload('p1')), 'p1');
    expect(arrivalPlaceIdFromPayload('focus'), isNull);
    expect(arrivalPlaceIdFromPayload('arrival:'), isNull);
  });
}
