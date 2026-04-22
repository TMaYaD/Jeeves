import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/providers/focus_session_provider.dart';
import 'package:jeeves/widgets/elapsed_timer_widget.dart';

Widget _wrap({required FocusModeState focusState}) {
  return ProviderScope(
    overrides: [
      focusModeProvider.overrideWith(() => _FakeFocusModeNotifier(focusState)),
    ],
    child: const MaterialApp(home: Scaffold(body: ElapsedTimerWidget())),
  );
}

class _FakeFocusModeNotifier extends FocusModeNotifier {
  _FakeFocusModeNotifier(this._initial);
  final FocusModeState _initial;

  @override
  FocusModeState build() => _initial;
}

Duration _minutes(int m) => Duration(minutes: m);

void main() {
  group('ElapsedTimerWidget.jeevesPhrase unit tests', () {
    test('< 5 min → empty (no phrase)', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(0)), '');
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(4)), '');
    });

    test('5-9 min → five-minute phrase', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(5)),
          'A trifling five minutes thus far, sir.');
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(9)),
          'A trifling five minutes thus far, sir.');
    });

    test('10-14 min → ten-minute phrase', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(10)),
          'Some ten minutes have elapsed, sir.');
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(14)),
          'Some ten minutes have elapsed, sir.');
    });

    test('15-29 min → quarter-hour phrase', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(15)),
          'A quarter-hour has passed, sir.');
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(29)),
          'A quarter-hour has passed, sir.');
    });

    test('30-44 min → half-hour phrase', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(30)),
          'Half an hour, if I may note, sir.');
    });

    test('45-59 min → three-quarters phrase', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(45)),
          'Three-quarters of an hour, sir.');
    });

    test('60-74 min → one-hour phrase', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(60)),
          'An hour has elapsed, sir.');
    });

    test('75-89 min → hour-and-a-quarter phrase', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(75)),
          'An hour and a quarter have passed, sir, if I may say so.');
    });

    test('90-104 min → hour-and-a-half phrase', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(90)),
          'An hour and a half, sir.');
    });

    test('105-119 min → hour-and-three-quarters phrase', () {
      expect(ElapsedTimerWidget.jeevesPhrase(_minutes(105)),
          'An hour and three-quarters, sir, if you will permit the observation.');
    });

    test('120-149 min → two-hour phrase with respite suggestion', () {
      final phrase = ElapsedTimerWidget.jeevesPhrase(_minutes(120));
      expect(phrase, contains('Two hours'));
      expect(phrase, contains('respite'));
    });

    test('150 min → two-and-a-half-hour phrase', () {
      final phrase = ElapsedTimerWidget.jeevesPhrase(_minutes(150));
      expect(phrase, contains('Two and a half'));
      expect(phrase, contains('respite'));
    });

    test('≥ 240 min → four-hour "Bertram" phrase', () {
      final phrase = ElapsedTimerWidget.jeevesPhrase(_minutes(300));
      expect(phrase, contains('Bertram'));
    });

    test('paused, < 5 min → standalone paused phrase', () {
      expect(
        ElapsedTimerWidget.jeevesPhrase(_minutes(3), isPaused: true),
        'Paused, sir.',
      );
    });

    test('paused, ≥ 5 min → phrase with paused suffix', () {
      final phrase = ElapsedTimerWidget.jeevesPhrase(_minutes(45), isPaused: true);
      expect(phrase, contains('Three-quarters'));
      expect(phrase, contains('Paused.'));
    });
  });

  group('ElapsedTimerWidget widget tests', () {
    testWidgets('shows nothing (SizedBox) when no session active', (tester) async {
      await tester.pumpWidget(_wrap(focusState: const FocusModeState()));
      await tester.pump();
      // No Text widget rendered — only SizedBox.shrink
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('shows nothing when elapsed < 5 min', (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 3));
      await tester.pumpWidget(_wrap(
        focusState: FocusModeState(sessionStart: start),
      ));
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('shows Jeeves phrase when elapsed ≥ 5 min', (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 7));
      await tester.pumpWidget(_wrap(
        focusState: FocusModeState(sessionStart: start),
      ));
      await tester.pump();
      expect(find.text('A trifling five minutes thus far, sir.'), findsOneWidget);
    });

    testWidgets('shows standalone paused phrase when elapsed < 5 min and paused',
        (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 2));
      final pauseStart = DateTime.now().subtract(const Duration(seconds: 30));
      await tester.pumpWidget(_wrap(
        focusState: FocusModeState(
          sessionStart: start,
          isPaused: true,
          pauseStart: pauseStart,
        ),
      ));
      await tester.pump();
      expect(find.text('Paused, sir.'), findsOneWidget);
    });

    testWidgets('display is frozen while paused', (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 47));
      final pauseStart = DateTime.now().subtract(const Duration(seconds: 10));
      final pausedState = FocusModeState(
        sessionStart: start,
        isPaused: true,
        pauseStart: pauseStart,
      );

      await tester.pumpWidget(_wrap(focusState: pausedState));
      await tester.pump();
      final textBefore = tester.widget<Text>(find.byType(Text)).data;

      // Advance time — the widget's Timer fires but elapsed is frozen.
      await tester.pump(const Duration(minutes: 2));
      final textAfter = tester.widget<Text>(find.byType(Text)).data;

      expect(textBefore, textAfter, reason: 'Paused timer should not change');
    });
  });
}
