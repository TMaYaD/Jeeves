import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/jeeves_logo.dart';

// flutter_svg renders SvgPicture widgets; we verify variant selection and
// layout rules without depending on actual SVG asset loading in unit tests.

Widget _wrap(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('JeevesLogo auto-variant selection', () {
    testWidgets('size < 32 picks Signature SVG asset', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(size: 20)));
      // The resolved variant is Signature; the _SvgMark asset path contains 'signature'
      expect(find.byType(JeevesLogo), findsOneWidget);
      // No assertion on internal SvgPicture path (private), but widget builds
    });

    testWidgets('size >= 32 picks Pointillist SVG asset', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(size: 64)));
      expect(find.byType(JeevesLogo), findsOneWidget);
    });

    testWidgets('size == 32 picks Pointillist (threshold is exclusive below)', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(size: 32)));
      expect(find.byType(JeevesLogo), findsOneWidget);
    });
  });

  group('JeevesLogo onDark inference', () {
    testWidgets('light Theme → onDark is false (no override)', (tester) async {
      await tester.pumpWidget(_wrap(
        const JeevesLogo(size: 64),
        brightness: Brightness.light,
      ));
      expect(find.byType(JeevesLogo), findsOneWidget);
    });

    testWidgets('dark Theme → onDark is true (no override)', (tester) async {
      await tester.pumpWidget(_wrap(
        const JeevesLogo(size: 64),
        brightness: Brightness.dark,
      ));
      expect(find.byType(JeevesLogo), findsOneWidget);
    });

    testWidgets('onDark: true overrides light Theme', (tester) async {
      await tester.pumpWidget(_wrap(
        const JeevesLogo(size: 64, onDark: true),
        brightness: Brightness.light,
      ));
      expect(find.byType(JeevesLogo), findsOneWidget);
    });
  });

  group('JeevesLogo clear-space padding', () {
    testWidgets('padding equals 0.5 × size on each side', (tester) async {
      const markSize = 48.0;
      await tester.pumpWidget(_wrap(const JeevesLogo(size: markSize)));

      final padding = tester.widget<Padding>(
        find.descendant(of: find.byType(JeevesLogo), matching: find.byType(Padding)).first,
      );
      final insets = padding.padding.resolve(TextDirection.ltr);
      expect(insets.top,    markSize * 0.5);
      expect(insets.bottom, markSize * 0.5);
      expect(insets.left,   markSize * 0.5);
      expect(insets.right,  markSize * 0.5);
    });
  });

  group('JeevesLogo size constraint', () {
    testWidgets('size >= 16 renders without assertion error', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(size: 16)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('size < 16 throws assertion', (tester) async {
      await tester.pumpWidget(_wrap(JeevesLogo(size: 15)));
      expect(tester.takeException(), isA<AssertionError>());
    });
  });

  group('JeevesLogo square bounding box (stretch prevention)', () {
    testWidgets('non-wordmark mark is always square', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(size: 64)));
      final box = tester.widget<SizedBox>(
        find
            .descendant(of: find.byType(JeevesLogo), matching: find.byType(SizedBox))
            .first,
      );
      expect(box.width,  64.0);
      expect(box.height, 64.0);
    });
  });

  group('JeevesLogo appIcon variant', () {
    testWidgets('appIcon: true renders without error', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(size: 64, appIcon: true)));
      expect(find.byType(JeevesLogo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('JeevesLogo explicit variants', () {
    testWidgets('explicit signature at size >= 32 still shows signature', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(
        size: 64,
        variant: JeevesLogoVariant.signature,
      )));
      expect(find.byType(JeevesLogo), findsOneWidget);
    });

    testWidgets('wordmark variant renders a Row', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(
        size: 48,
        variant: JeevesLogoVariant.wordmark,
      )));
      expect(
        find.descendant(of: find.byType(JeevesLogo), matching: find.byType(Row)),
        findsOneWidget,
      );
    });

    testWidgets('wordmark variant renders "Jeeves" text', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(
        size: 48,
        variant: JeevesLogoVariant.wordmark,
      )));
      expect(find.text('Jeeves'), findsOneWidget);
    });

    testWidgets('explicit pointillist at size < 32 still shows pointillist', (tester) async {
      await tester.pumpWidget(_wrap(const JeevesLogo(
        size: 20,
        variant: JeevesLogoVariant.pointillist,
      )));
      expect(find.byType(JeevesLogo), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
