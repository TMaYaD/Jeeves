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

    test('size < 16 throws assertion', () {
      expect(() => JeevesLogo(size: 15), throwsAssertionError);
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

  group('JeevesLogo explicit variants', () {
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
  });
}
