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
  // Seed templates are drawn from a pool now; phrases are asserted by the
  // stable duration substring plus tier-appropriate flavour. A fixed seed
  // keeps template selection deterministic across runs. Lowercased so that
  // assertions don't have to care whether the duration falls at the start
  // of a sentence (where the first letter is capitalized).
  String phrase(int m, {bool isPaused = false, int seed = 0}) =>
      ElapsedTimerWidget.jeevesPhrase(_minutes(m), isPaused: isPaused, seed: seed)
          .toLowerCase();

  group('ElapsedTimerWidget.jeevesPhrase unit tests', () {
    test('< 5 min → just-started phrase', () {
      expect(
        phrase(0),
        anyOf(contains('begun'), contains('underway'), contains('commenced')),
      );
      expect(
        phrase(4),
        anyOf(contains('begun'), contains('underway'), contains('commenced')),
      );
    });

    test('5-9 min → five-minute phrase', () {
      expect(phrase(5), contains('five minutes'));
      expect(phrase(9), contains('five minutes'));
    });

    test('10-14 min → ten-minute phrase', () {
      expect(phrase(10), contains('ten minutes'));
      expect(phrase(14), contains('ten minutes'));
    });

    test('15-29 min → quarter-hour phrase', () {
      expect(phrase(15), contains('quarter-hour'));
      expect(phrase(29), contains('quarter-hour'));
    });

    test('30-44 min → half-hour phrase', () {
      expect(phrase(30), contains('half an hour'));
    });

    test('45-59 min → three-quarters phrase', () {
      expect(phrase(45), contains('three-quarters of an hour'));
    });

    test('60-74 min → one-hour phrase', () {
      expect(phrase(60), contains('an hour'));
    });

    test('75-89 min → hour-and-a-quarter phrase', () {
      expect(phrase(75), contains('an hour and a quarter'));
    });

    test('90-104 min → hour-and-a-half phrase', () {
      expect(phrase(90), contains('an hour and a half'));
    });

    test('105-119 min → hour-and-three-quarters phrase', () {
      expect(phrase(105), contains('an hour and three-quarters'));
    });

    test('120-149 min → two-hour phrase with respite suggestion', () {
      final p = phrase(120);
      expect(p, contains('two hours'));
      expect(p, anyOf(contains('respite'), contains('pause'), contains('interval')));
    });

    test('150 min → two-and-a-half-hour phrase', () {
      final p = phrase(150);
      expect(p, contains('two and a half hours'));
      expect(p, anyOf(contains('respite'), contains('pause'), contains('interval')));
    });

    test('180-239 min → stronger insistence on respite', () {
      final p = phrase(180);
      expect(p, contains('three hours'));
      expect(p, anyOf(contains('insist'), contains('protest'), contains('pause')));
    });

    test('≥ 240 min → strongest remonstrance', () {
      final p = phrase(300);
      expect(p, contains('hours'));
      expect(
        p,
        anyOf(contains('stop'), contains('enough'), contains('put the matter down')),
      );
    });

    test('seed produces deterministic selection', () {
      // Same seed → same string; different seed → (usually) a different one.
      expect(phrase(45, seed: 7), phrase(45, seed: 7));
    });

    // Every Jeeves-voice paused utterance carries one of these markers.
    final pausedMarker = anyOf(
      contains('rest'),
      contains('reprieve'),
      contains('abeyance'),
    );

    test('paused, < 5 min → just-started Jeeves-voice paused prose', () {
      final p = phrase(3, isPaused: true);
      expect(p, anyOf(contains('begun'), contains('underway')));
      expect(p, pausedMarker);
    });

    test('paused, ≥ 5 min → Jeeves-voice paused prose with duration', () {
      final p = phrase(45, isPaused: true);
      expect(p, contains('three-quarters of an hour'));
      expect(p, pausedMarker);
    });

    test("phrase always begins with a capital letter (Jeeves's standards)", () {
      // Sample across all duration tiers; the first character must be uppercase
      // regardless of whether the template starts with the duration token.
      for (final m in [0, 7, 12, 22, 47, 62, 78, 95, 110, 135, 165, 200, 320]) {
        for (final seed in [0, 1, 2, 3]) {
          final raw = ElapsedTimerWidget.jeevesPhrase(_minutes(m), seed: seed);
          expect(raw[0], equals(raw[0].toUpperCase()),
              reason: 'phrase($m, seed=$seed) starts lowercase: $raw');
        }
      }
    });
  });

  group('ElapsedTimerWidget widget tests', () {
    testWidgets('shows nothing (SizedBox) when no session active', (tester) async {
      await tester.pumpWidget(_wrap(focusState: const FocusModeState()));
      await tester.pump();
      // No Text widget rendered — only SizedBox.shrink
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('shows just-started phrase when elapsed < 5 min', (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 3));
      await tester.pumpWidget(_wrap(
        focusState: FocusModeState(activeTodoId: 't1', sessionStart: start),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.byType(Text)).data!;
      expect(
        text,
        anyOf(contains('begun'), contains('Underway'), contains('commenced')),
      );
    });

    testWidgets('shows Jeeves phrase when elapsed ≥ 5 min', (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 7));
      await tester.pumpWidget(_wrap(
        focusState: FocusModeState(activeTodoId: 't1', sessionStart: start),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.byType(Text)).data!;
      expect(text, contains('five minutes'));
    });

    testWidgets('appends paused suffix when elapsed < 5 min and paused',
        (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 2));
      final pauseStart = DateTime.now().subtract(const Duration(seconds: 30));
      await tester.pumpWidget(_wrap(
        focusState: FocusModeState(
          activeTodoId: 't1',
          sessionStart: start,
          isPaused: true,
          pauseStart: pauseStart,
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.byType(Text)).data!;
      expect(text, anyOf(contains('begun'), contains('underway')));
      expect(
        text,
        anyOf(
          contains('rest'),
          contains('reprieve'),
          contains('abeyance'),
        ),
      );
    });

    testWidgets('display is frozen while paused', (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 47));
      final pauseStart = DateTime.now().subtract(const Duration(seconds: 10));
      final pausedState = FocusModeState(
        activeTodoId: 't1',
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
