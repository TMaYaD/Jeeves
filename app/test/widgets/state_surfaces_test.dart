/// Widget tests for the surfaces shared by [AsyncList] and [AsyncSubject].
///
/// The layout concern here is not cosmetic: [EmptySurface] carries the missing
/// state's CTA, which #428 requires to be reachable. A panel that overflows —
/// large accessibility text, a short landscape viewport — pushes that button
/// off-screen and re-creates the dead end the issue exists to remove.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/widgets/state_surfaces.dart';

/// Renders [child] at [size] with [textScale] applied, so the surface is
/// squeezed exactly the way an accessibility setting on a short screen would.
Widget _squeezed(
  Widget child, {
  double textScale = 1.0,
}) =>
    MaterialApp(
      builder: (context, inner) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: inner!,
      ),
      home: Scaffold(body: child),
    );

void main() {
  group('EmptySurface — the missing state stays usable when squeezed', () {
    Future<void> setViewport(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    testWidgets('a full panel at large text on a short viewport does not '
        'overflow, and the CTA is still reachable', (tester) async {
      // Landscape-ish phone height with accessibility text scaling — icon,
      // title, subtitle and CTA together exceed the viewport.
      await setViewport(tester, const Size(400, 300));

      await tester.pumpWidget(_squeezed(
        textScale: 3.0,
        EmptySurface(
          icon: Icons.inbox_outlined,
          title: 'This item is no longer in your Inbox',
          subtitle: 'It may have been deleted on another device.',
          cta: FilledButton(
            onPressed: () {},
            child: const Text('Back to Inbox'),
          ),
        ),
      ));

      expect(tester.takeException(), isNull,
          reason: 'the panel must scroll rather than overflow');

      // The escape must be reachable, not merely present in the tree.
      await tester.ensureVisible(find.text('Back to Inbox'));
      await tester.pump();
      expect(find.text('Back to Inbox'), findsOneWidget);
    });

    testWidgets('the CTA is tappable once scrolled into view', (tester) async {
      await setViewport(tester, const Size(400, 300));
      var tapped = 0;

      await tester.pumpWidget(_squeezed(
        textScale: 3.0,
        EmptySurface(
          icon: Icons.inbox_outlined,
          title: 'This item is no longer in your Inbox',
          subtitle: 'It may have been deleted on another device.',
          cta: FilledButton(
            onPressed: () => tapped++,
            child: const Text('Back to Inbox'),
          ),
        ),
      ));

      await tester.ensureVisible(find.text('Back to Inbox'));
      await tester.pump();
      await tester.tap(find.text('Back to Inbox'));
      await tester.pump();

      expect(tapped, 1);
    });

    testWidgets('content that fits stays centred rather than pinned to the top',
        (tester) async {
      // The scroll view must shrink-wrap under loose constraints, or every
      // shipped empty state silently changes from centred to top-aligned.
      await setViewport(tester, const Size(400, 800));

      await tester.pumpWidget(_squeezed(
        const EmptySurface(
          icon: Icons.inbox_outlined,
          title: 'Nothing here yet',
        ),
      ));

      expect(tester.takeException(), isNull);
      final titleCentre = tester.getCenter(find.text('Nothing here yet'));
      final bodyCentre = tester.getCenter(find.byType(Scaffold));
      expect((titleCentre.dy - bodyCentre.dy).abs(), lessThan(40),
          reason: 'a panel that fits must remain vertically centred');
    });
  });
}
