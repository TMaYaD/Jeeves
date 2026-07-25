/// Widget + unit tests for the shared ceremony intro step (#486).
///
/// Covers the duration display (round-up-to-5, floored at 5), the light-day
/// variant at zero items, the seeded copy draw, the loading placeholder, and
/// the inline bold/larger/accent duration run (visual layout B).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/ceremony/intro_step.dart';

const _accent = Color(0xFF2563EB);

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

CeremonyIntroBody _body(IntroEstimate estimate, {int? seed}) => CeremonyIntroBody(
      accentColor: _accent,
      estimate: estimate,
      bodyPool: dprIntroBodyPool,
      lightDayPool: introLightDayPool,
      seed: seed,
    );

/// Finds the styled duration [TextSpan] inside the rendered [Text.rich].
TextSpan? _durationSpan(WidgetTester tester) {
  final richText = tester.widget<RichText>(find.byType(RichText).last);
  TextSpan? found;
  richText.text.visitChildren((span) {
    if (span is TextSpan &&
        (span.text?.startsWith('about ') ?? false) &&
        span.style?.fontWeight == FontWeight.w700) {
      found = span;
      return false;
    }
    return true;
  });
  return found;
}

void main() {
  group('introDisplayMinutes / introDurationText', () {
    test('rounds up to the nearest 5', () {
      expect(introDisplayMinutes(21), 25); // DPR 2×8+5
      expect(introDisplayMinutes(25), 25);
      expect(introDisplayMinutes(26), 30);
      expect(introDisplayMinutes(7), 10);
    });

    test('floors at 5 (a zero-item ceremony never reads 0)', () {
      expect(introDisplayMinutes(0), 5);
      expect(introDisplayMinutes(3), 5);
      expect(introDurationText(0), 'about 5 minutes');
    });

    test('plural/singular grammar', () {
      expect(introDurationText(21), 'about 25 minutes');
      expect(introDurationText(0), 'about 5 minutes');
    });
  });

  group('introCtaLabel', () {
    test('draws from the Bertie pool; seeded draw is deterministic', () {
      expect(introCtaPool, contains('Tinkerty-tonk'));
      final a = introCtaLabel(seed: 7);
      final b = introCtaLabel(seed: 7);
      expect(a, b);
      expect(introCtaPool, contains(a));
    });
  });

  group('CeremonyIntroBody', () {
    testWidgets('renders "about N minutes" for a ready estimate', (tester) async {
      await tester.pumpWidget(_wrap(_body(
        const IntroEstimateReady(rawMinutes: 21, itemCount: 8),
        seed: 1,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('about 25 minutes'), findsOneWidget);
    });

    testWidgets('the duration run is bold, larger, and in the accent colour',
        (tester) async {
      await tester.pumpWidget(_wrap(_body(
        const IntroEstimateReady(rawMinutes: 21, itemCount: 8),
        seed: 1,
      )));
      await tester.pumpAndSettle();

      final span = _durationSpan(tester);
      expect(span, isNotNull, reason: 'the {duration} slot is a styled run');
      expect(span!.text, 'about 25 minutes');
      expect(span.style!.fontWeight, FontWeight.w700);
      expect(span.style!.color, _accent);
      // Larger than the surrounding sentence (20px base).
      expect(span.style!.fontSize, greaterThan(20));
    });

    testWidgets('light-day variant at zero items shows the floor, never "0"',
        (tester) async {
      await tester.pumpWidget(_wrap(_body(
        const IntroEstimateReady(rawMinutes: 0, itemCount: 0),
        seed: 1,
      )));
      await tester.pumpAndSettle();

      expect(find.textContaining('about 5 minutes'), findsOneWidget);
      expect(find.textContaining('0 minutes'), findsNothing);
    });

    testWidgets('seeded draw is deterministic across mounts', (tester) async {
      String plainTextOf(WidgetTester t) =>
          t.widget<RichText>(find.byType(RichText).last).text.toPlainText();

      await tester.pumpWidget(_wrap(_body(
        const IntroEstimateReady(rawMinutes: 21, itemCount: 8),
        seed: 42,
      )));
      await tester.pumpAndSettle();
      final first = plainTextOf(tester);

      await tester.pumpWidget(_wrap(const SizedBox.shrink()));
      await tester.pumpWidget(_wrap(_body(
        const IntroEstimateReady(rawMinutes: 21, itemCount: 8),
        seed: 42,
      )));
      await tester.pumpAndSettle();
      expect(plainTextOf(tester), first);
    });

    testWidgets('the copy line stays stable across the loading→ready rebuild',
        (tester) async {
      // A stateful harness that swaps the estimate loading→ready in place, so
      // the CeremonyIntroBody state (and its memoized draw) persists.
      late StateSetter setOuter;
      IntroEstimate estimate = const IntroEstimateLoading();
      await tester.pumpWidget(_wrap(StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return _body(estimate, seed: 3);
        },
      )));
      await tester.pumpAndSettle();
      expect(find.textContaining('taking stock'), findsOneWidget);

      setOuter(() => estimate =
          const IntroEstimateReady(rawMinutes: 21, itemCount: 8));
      await tester.pumpAndSettle();

      final readyText =
          tester.widget<RichText>(find.byType(RichText).last).text.toPlainText();
      expect(readyText, contains('about 25 minutes'));
    });

    testWidgets('loading estimate shows a quiet placeholder, no duration',
        (tester) async {
      await tester.pumpWidget(_wrap(_body(const IntroEstimateLoading())));
      await tester.pumpAndSettle();

      expect(find.textContaining('taking stock'), findsOneWidget);
      expect(find.textContaining('minutes'), findsNothing);
    });
  });
}
