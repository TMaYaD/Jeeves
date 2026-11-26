/// The arrival visit rule (issue #1092).
///
/// A visit is one stay at a Place. The rule decides when an arrival starts a
/// new visit, and whether that arrival may notify the user.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/services/arrival_visit_rule.dart';

void main() {
  // The moment the user walks into the Place.
  final arrival = DateTime.utc(2026, 11, 26, 9);

  test('the first arrival notifies when something is due', () {
    final result = onEnter(null, nowUtc: arrival, somethingDue: true);

    expect(result.notify, isTrue);
    expect(result.visit.inside, isTrue);
    expect(result.visit.notifiedThisVisit, isTrue);
  });

  test('an arrival after a short absence is the same visit, and stays quiet',
      () {
    final entered = onEnter(null, nowUtc: arrival, somethingDue: true);
    final left = onExit(entered.visit, nowUtc: arrival);

    final again = onEnter(
      left,
      nowUtc: arrival.add(const Duration(minutes: 29)),
      somethingDue: true,
    );

    expect(again.notify, isFalse);
    expect(again.visit.notifiedThisVisit, isTrue);
  });

  test('an arrival after the gap is a new visit, and notifies again', () {
    final entered = onEnter(null, nowUtc: arrival, somethingDue: true);
    final left = onExit(entered.visit, nowUtc: arrival);

    final again = onEnter(
      left,
      nowUtc: arrival.add(const Duration(minutes: 30)),
      somethingDue: true,
    );

    expect(again.notify, isTrue);
    expect(again.visit.notifiedThisVisit, isTrue);
  });

  test('two arrivals without an absence notify once', () {
    final first = onEnter(null, nowUtc: arrival, somethingDue: true);

    final second = onEnter(
      first.visit,
      nowUtc: arrival.add(const Duration(minutes: 5)),
      somethingDue: true,
    );

    expect(second.notify, isFalse);
    expect(second.visit, first.visit);
  });

  test('an arrival notifies when something became due during the visit', () {
    final entered = onEnter(null, nowUtc: arrival, somethingDue: false);
    expect(entered.notify, isFalse);

    final left = onExit(entered.visit, nowUtc: arrival);
    final again = onEnter(
      left,
      nowUtc: arrival.add(const Duration(minutes: 10)),
      somethingDue: true,
    );

    // The visit is the same one, but it has not told the user yet.
    expect(again.notify, isTrue);
    expect(again.visit.notifiedThisVisit, isTrue);
  });

  test('nothing due never notifies', () {
    final entered = onEnter(null, nowUtc: arrival, somethingDue: false);
    expect(entered.notify, isFalse);

    final left = onExit(entered.visit, nowUtc: arrival);
    final again = onEnter(
      left,
      nowUtc: arrival.add(const Duration(hours: 2)),
      somethingDue: false,
    );

    expect(again.notify, isFalse);
    expect(again.visit.notifiedThisVisit, isFalse);
  });
}
