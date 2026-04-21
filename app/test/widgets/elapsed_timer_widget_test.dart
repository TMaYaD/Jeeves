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

void main() {
  group('ElapsedTimerWidget', () {
    testWidgets('shows 00:MM:SS when elapsed < 1 hour', (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 5, seconds: 3));
      await tester.pumpWidget(_wrap(
        focusState: FocusModeState(sessionStart: start),
      ));
      await tester.pump();

      // Should show something like "00:05:03"
      final text = tester.widget<Text>(find.byType(Text)).data ?? '';
      expect(RegExp(r'^\d{2}:\d{2}:\d{2}$').hasMatch(text), isTrue,
          reason: 'Expected HH:MM:SS format, got "$text"');
      expect(text.startsWith('00:'), isTrue,
          reason: 'Sub-hour sessions should start with "00:", got "$text"');
    });

    testWidgets('shows HH:MM:SS when elapsed >= 1 hour', (tester) async {
      final start =
          DateTime.now().subtract(const Duration(hours: 1, minutes: 2, seconds: 5));
      await tester.pumpWidget(_wrap(
        focusState: FocusModeState(sessionStart: start),
      ));
      await tester.pump();

      final text = tester.widget<Text>(find.byType(Text)).data ?? '';
      expect(RegExp(r'^\d{2}:\d{2}:\d{2}$').hasMatch(text), isTrue,
          reason: 'Expected HH:MM:SS format, got "$text"');
    });

    testWidgets('shows 00:00:00 when no session active', (tester) async {
      await tester.pumpWidget(_wrap(focusState: const FocusModeState()));
      await tester.pump();

      expect(find.text('00:00:00'), findsOneWidget);
    });

    testWidgets('display is frozen while paused', (tester) async {
      final start = DateTime.now().subtract(const Duration(minutes: 3));
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
      await tester.pump(const Duration(seconds: 3));
      final textAfter = tester.widget<Text>(find.byType(Text)).data;

      // The displayed time should be ~2:50 (3m - 10s), unchanged after 3s.
      expect(textBefore, textAfter,
          reason: 'Paused timer should not advance');
    });
  });
}
