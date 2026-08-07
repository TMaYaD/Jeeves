import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart'
    show appTitleBarOverflowKey;

export 'package:jeeves/widgets/app_title_bar/app_title_bar.dart'
    show appTitleBarBadgeKey, appTitleBarLeadingKey, appTitleBarOverflowKey;

/// Test finders for `AppTitleBar` actions.
///
/// Where an action renders depends on the width breakpoint: the
/// same action sits in the bar on a wide surface and inside the ⋮ menu on a
/// narrow one. Screen tests must therefore never `find.byKey` a bar action
/// directly — they go through these helpers, which look in the bar first and
/// open the overflow menu when the action is not there.

/// Finds the bar action carrying [actionKey] wherever the breakpoint put it.
///
/// Opens the ⋮ menu when the action is not in the bar; fails with a readable
/// message when the action is in neither place.
Future<Finder> findBarAction(WidgetTester tester, Key actionKey) async {
  final inBar = find.byKey(actionKey);
  if (inBar.evaluate().isNotEmpty) return inBar;

  final overflow = find.byKey(appTitleBarOverflowKey);
  if (overflow.evaluate().isEmpty) {
    fail('No title-bar action with key $actionKey, and no ⋮ overflow button '
        'to look inside.');
  }

  await tester.tap(overflow);
  await tester.pumpAndSettle();

  final inMenu = find.byKey(actionKey);
  if (inMenu.evaluate().isEmpty) {
    fail('No title-bar action with key $actionKey — neither in the bar nor '
        'in the ⋮ overflow menu.');
  }
  return inMenu;
}

/// Taps the bar action carrying [actionKey], opening the ⋮ menu first when the
/// breakpoint put the action there. Tapping a menu item dismisses the menu, so
/// the caller is left with the plain screen either way.
Future<void> tapBarAction(WidgetTester tester, Key actionKey) async {
  final finder = await findBarAction(tester, actionKey);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
