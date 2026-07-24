import 'package:flutter/widgets.dart';

/// One action offered by [AppTitleBar].
///
/// Actions are held in a list whose order *is* their priority (index 0 =
/// highest); there is no priority field to get out of step with the list.
/// Overflow takes from the tail, so the lowest-priority action is the first to
/// disappear into the ⋮ menu.
class AppTitleBarAction {
  const AppTitleBarAction({
    required this.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  /// Stable identity, and the test contract: the same key finds the action
  /// whether the breakpoint put it in the bar or in the ⋮ menu (see
  /// `test/helpers/app_title_bar_test_helpers.dart`).
  final Key key;

  final IconData icon;

  /// Tooltip in the bar; the row's text inside the ⋮ menu.
  final String label;

  /// `null` renders the action disabled rather than hiding it.
  final VoidCallback? onPressed;

  /// Foreground override, for actions that carry a call-to-action colour
  /// (task detail's Start focus keeps the primary blue).
  final Color? color;
}

/// The small label — with an optional icon — that sits above the title.
///
/// Names the thing the title belongs to: the project above a task title, the
/// ceremony above a step title.
class AppTitleBarOverline {
  const AppTitleBarOverline({required this.label, this.icon, this.iconColor});

  final String label;
  final IconData? icon;
  final Color? iconColor;
}

/// A count rendered adjacent to the title — the Inbox's unprocessed count is
/// the motivating case.
///
/// Typed rather than a free-form widget or a number smuggled into the title
/// string, so every screen's badge looks and reads the same.
class AppTitleBarBadge {
  const AppTitleBarBadge({required this.count, this.semanticsLabel});

  final int count;

  /// Screen-reader text; defaults to the bare count, which is meaningless out
  /// of context — pass e.g. '7 unprocessed captures'.
  final String? semanticsLabel;
}

/// What the bar's leading slot does. Passed in by the screen, never inferred
/// from router state: the bar must stay a pure function of its parameters.
enum AppTitleBarLeading { back, drawer, none }
