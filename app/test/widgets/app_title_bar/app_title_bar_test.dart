import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';

import '../../helpers/app_title_bar_test_helpers.dart';

const _phone = Size(375, 800);
const _mid = Size(800, 900);
const _desktop = Size(1280, 900);

AppTitleBarAction _action(String id, {VoidCallback? onPressed}) =>
    AppTitleBarAction(
      key: Key(id),
      icon: Icons.star_outline,
      label: id,
      onPressed: onPressed ?? () {},
    );

Widget _harness(
  AppTitleBar bar, {
  Size size = _phone,
  Widget? drawer,
}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(
          appBar: bar,
          drawer: drawer,
          body: const SizedBox.expand(),
        ),
      ),
    );

void main() {
  group('action budget by breakpoint', () {
    testWidgets('phone shows three actions and no ⋮ when they fit',
        (tester) async {
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [_action('a1'), _action('a2'), _action('a3')],
        ),
      ));

      expect(find.byKey(const Key('a1')), findsOneWidget);
      expect(find.byKey(const Key('a2')), findsOneWidget);
      expect(find.byKey(const Key('a3')), findsOneWidget);
      expect(find.byKey(appTitleBarOverflowKey), findsNothing);
    });

    testWidgets('phone overflows the tail once the budget is exceeded',
        (tester) async {
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [
            _action('a1'),
            _action('a2'),
            _action('a3'),
            _action('a4'),
          ],
        ),
      ));

      // budget 3, no pinned → 2 visible + ⋮.
      expect(find.byKey(const Key('a1')), findsOneWidget);
      expect(find.byKey(const Key('a2')), findsOneWidget);
      expect(find.byKey(const Key('a3')), findsNothing);
      expect(find.byKey(const Key('a4')), findsNothing);
      expect(find.byKey(appTitleBarOverflowKey), findsOneWidget);
    });

    testWidgets('mid width fits one more action than phone', (tester) async {
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [
            _action('a1'),
            _action('a2'),
            _action('a3'),
            _action('a4'),
          ],
        ),
        size: _mid,
      ));

      expect(find.byKey(const Key('a4')), findsOneWidget);
      expect(find.byKey(appTitleBarOverflowKey), findsNothing);
    });

    testWidgets('desktop fits five actions', (tester) async {
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [
            _action('a1'),
            _action('a2'),
            _action('a3'),
            _action('a4'),
            _action('a5'),
          ],
        ),
        size: _desktop,
      ));

      expect(find.byKey(const Key('a5')), findsOneWidget);
      expect(find.byKey(appTitleBarOverflowKey), findsNothing);
    });
  });

  group('slot order (owner ruling)', () {
    testWidgets(
        'two actions + pinned on a phone render [a2][a1][pinned] with no ⋮',
        (tester) async {
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [_action('a1'), _action('a2')],
          pinnedAction: _action('pinned'),
        ),
      ));

      expect(find.byKey(appTitleBarOverflowKey), findsNothing);
      final a2 = tester.getCenter(find.byKey(const Key('a2'))).dx;
      final a1 = tester.getCenter(find.byKey(const Key('a1'))).dx;
      final pinned = tester.getCenter(find.byKey(const Key('pinned'))).dx;
      expect(a2, lessThan(a1),
          reason: 'page actions ascend in priority left to right');
      expect(a1, lessThan(pinned),
          reason: 'the highest-priority action sits nearest the pinned slot');
    });

    testWidgets(
        'three actions + pinned on a phone render [a1][pinned][⋮ → a2, a3]',
        (tester) async {
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [_action('a1'), _action('a2'), _action('a3')],
          pinnedAction: _action('pinned'),
        ),
      ));

      expect(find.byKey(const Key('a1')), findsOneWidget);
      expect(find.byKey(const Key('a2')), findsNothing);
      expect(find.byKey(const Key('a3')), findsNothing);

      final a1 = tester.getCenter(find.byKey(const Key('a1'))).dx;
      final pinned = tester.getCenter(find.byKey(const Key('pinned'))).dx;
      final overflow = tester.getCenter(find.byKey(appTitleBarOverflowKey)).dx;
      expect(a1, lessThan(pinned));
      expect(pinned, lessThan(overflow),
          reason: 'the ⋮ is rightmost when it renders at all');
    });

    testWidgets('overflowed actions appear in the ⋮ menu in priority order',
        (tester) async {
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [_action('a1'), _action('a2'), _action('a3')],
          pinnedAction: _action('pinned'),
        ),
      ));

      await tester.tap(find.byKey(appTitleBarOverflowKey));
      await tester.pumpAndSettle();

      final a2 = tester.getCenter(find.byKey(const Key('a2'))).dy;
      final a3 = tester.getCenter(find.byKey(const Key('a3'))).dy;
      expect(a2, lessThan(a3));
      expect(find.text('a2'), findsOneWidget);
      expect(find.text('a3'), findsOneWidget);
      expect(find.byKey(const Key('pinned')), findsOneWidget,
          reason: 'the pinned action stays in the bar, never in the menu');
    });

    testWidgets('the pinned action holds the same slot at every breakpoint',
        (tester) async {
      for (final size in [_phone, _mid, _desktop]) {
        await tester.pumpWidget(_harness(
          AppTitleBar(
            title: 'Title',
            leading: AppTitleBarLeading.none,
            pageActions: [
              _action('a1'),
              _action('a2'),
              _action('a3'),
              _action('a4'),
            ],
            pinnedAction: _action('pinned'),
          ),
          size: size,
        ));

        final pinned = tester.getCenter(find.byKey(const Key('pinned'))).dx;
        final overflow = find.byKey(appTitleBarOverflowKey);
        if (overflow.evaluate().isNotEmpty) {
          expect(pinned, lessThan(tester.getCenter(overflow).dx),
              reason: 'the ⋮ is the only thing right of the pinned slot');
        }
        for (var i = 1; i <= 4; i++) {
          final action = find.byKey(Key('a$i'));
          if (action.evaluate().isEmpty) continue;
          expect(tester.getCenter(action).dx, lessThan(pinned),
              reason: 'every visible page action sits left of the pinned slot '
                  'at width ${size.width}');
        }
      }
    });

    testWidgets('an action with a null callback renders disabled',
        (tester) async {
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [
            AppTitleBarAction(
              key: const Key('a1'),
              icon: Icons.star_outline,
              label: 'a1',
              onPressed: null,
            ),
          ],
        ),
      ));

      final button = tester.widget<IconButton>(find.byKey(const Key('a1')));
      expect(button.onPressed, isNull);
    });
  });

  group('title and overline', () {
    testWidgets('renders the title, ellipsised on one line', (tester) async {
      await tester.pumpWidget(_harness(
        const AppTitleBar(
          title: 'A very long task title that cannot possibly fit the bar',
          leading: AppTitleBarLeading.none,
        ),
      ));

      final title = tester.widget<Text>(find.text(
          'A very long task title that cannot possibly fit the bar'));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
    });

    testWidgets('renders the overline label and icon above the title',
        (tester) async {
      await tester.pumpWidget(_harness(
        const AppTitleBar(
          title: 'Task title',
          overline: AppTitleBarOverline(
            label: 'Kitchen remodel',
            icon: Icons.folder_outlined,
          ),
          leading: AppTitleBarLeading.none,
        ),
      ));

      expect(find.text('Kitchen remodel'), findsOneWidget);
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
      expect(
        tester.getCenter(find.text('Kitchen remodel')).dy,
        lessThan(tester.getCenter(find.text('Task title')).dy),
      );
    });

    testWidgets('an overline makes the bar taller', (tester) async {
      const plain = AppTitleBar(title: 'T');
      const withOverline = AppTitleBar(
        title: 'T',
        overline: AppTitleBarOverline(label: 'Project'),
      );
      expect(withOverline.preferredSize.height,
          greaterThan(plain.preferredSize.height));
    });

    testWidgets('no overline renders when none is given', (tester) async {
      await tester.pumpWidget(_harness(
        const AppTitleBar(title: 'Task title'),
      ));
      expect(find.byType(Icon), findsOneWidget,
          reason: 'only the back leading icon');
    });
  });

  group('badge', () {
    testWidgets('renders the count beside the title when given',
        (tester) async {
      await tester.pumpWidget(_harness(
        const AppTitleBar(
          title: 'Inbox',
          leading: AppTitleBarLeading.none,
          badge: AppTitleBarBadge(
            count: 7,
            semanticsLabel: '7 unprocessed captures',
          ),
        ),
      ));

      expect(find.byKey(appTitleBarBadgeKey), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      final badge = tester.getCenter(find.byKey(appTitleBarBadgeKey));
      final title = tester.getCenter(find.text('Inbox'));
      expect(title.dx, lessThan(badge.dx),
          reason: 'the badge sits after the title');
      expect((title.dy - badge.dy).abs(), lessThan(4),
          reason: 'and on the same line');
    });

    testWidgets('renders nothing when null', (tester) async {
      await tester.pumpWidget(_harness(
        const AppTitleBar(
          title: 'Inbox',
          leading: AppTitleBarLeading.none,
        ),
      ));

      expect(find.byKey(appTitleBarBadgeKey), findsNothing);
    });

    testWidgets('leaves the title ellipsised and the action budget untouched',
        (tester) async {
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'A very long inbox title that cannot possibly fit the bar',
          leading: AppTitleBarLeading.none,
          badge: const AppTitleBarBadge(count: 12),
          pageActions: [_action('a1'), _action('a2'), _action('a3')],
        ),
      ));

      final title = tester.widget<Text>(find.text(
          'A very long inbox title that cannot possibly fit the bar'));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);

      // Phone budget of 3 is spent on actions alone — a badge is not an
      // action and costs no slot.
      expect(find.byKey(const Key('a3')), findsOneWidget);
      expect(find.byKey(appTitleBarOverflowKey), findsNothing);
      expect(find.byKey(appTitleBarBadgeKey), findsOneWidget);
    });
  });

  group('leading slot', () {
    testWidgets('drawer opens the ambient Scaffold drawer', (tester) async {
      await tester.pumpWidget(_harness(
        const AppTitleBar(
          title: 'Inbox',
          leading: AppTitleBarLeading.drawer,
        ),
        drawer: const Drawer(child: Text('Drawer contents')),
      ));

      expect(find.text('Drawer contents'), findsNothing);
      await tester.tap(find.byKey(appTitleBarLeadingKey));
      await tester.pumpAndSettle();
      expect(find.text('Drawer contents'), findsOneWidget);
    });

    testWidgets('back pops the route', (tester) async {
      final router = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: router,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    appBar: AppTitleBar(title: 'Pushed'),
                    body: SizedBox.expand(),
                  ),
                ),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('Pushed'), findsOneWidget);

      await tester.tap(find.byKey(appTitleBarLeadingKey));
      await tester.pumpAndSettle();
      expect(find.text('Pushed'), findsNothing);
    });

    testWidgets('onLeadingPressed overrides the default', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Active focus',
          onLeadingPressed: () => pressed++,
        ),
      ));

      await tester.tap(find.byKey(appTitleBarLeadingKey));
      await tester.pumpAndSettle();
      expect(pressed, 1);
    });

    testWidgets('none renders no leading affordance', (tester) async {
      await tester.pumpWidget(_harness(
        const AppTitleBar(
          title: 'Daily Planning',
          leading: AppTitleBarLeading.none,
        ),
      ));

      expect(find.byKey(appTitleBarLeadingKey), findsNothing);
    });
  });

  group('overflow-aware test helper', () {
    testWidgets('finds and taps an action rendered in the bar', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [_action('a1', onPressed: () => taps++)],
        ),
      ));

      await tapBarAction(tester, const Key('a1'));
      expect(taps, 1);
    });

    testWidgets('finds and taps an action hiding in the ⋮ menu',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(_harness(
        AppTitleBar(
          title: 'Title',
          leading: AppTitleBarLeading.none,
          pageActions: [
            _action('a1'),
            _action('a2'),
            _action('a3', onPressed: () => taps++),
          ],
          pinnedAction: _action('pinned'),
        ),
      ));

      await tapBarAction(tester, const Key('a3'));
      expect(taps, 1);
      expect(find.byKey(const Key('a3')), findsNothing,
          reason: 'the menu closed itself on tap');
    });
  });
}
