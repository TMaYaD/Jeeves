import 'package:flutter/material.dart';

import 'action_budget.dart';
import 'app_title_bar_action.dart';

export 'action_budget.dart';
export 'app_title_bar_action.dart';

/// The app's one title bar (DESIGN.md § App title bar).
///
/// Mounted in `Scaffold.appBar` on every screen, and configured **entirely by
/// constructor parameters passed top-down** — deliberately not a provider or
/// `content_for`-style slot written into from below. During a route transition
/// two screens coexist; writes-from-below would race (last writer wins) and
/// flicker. With parameters, the bar a screen renders is a pure function of
/// what that screen passed, so neither bug can happen.
///
/// Layout, left to right:
///
///     [leading] [overline / title] [badge] … [page actions] [pinned] [⋮]
///
/// Page actions ascend in priority towards the pinned slot, so the
/// highest-priority action is the one nearest the pinned capture affordance.
/// The pinned slot never overflows and never moves. The ⋮ renders **only**
/// when something actually overflowed. See [actionBudget] / [splitActions] for
/// the arithmetic.
class AppTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const AppTitleBar({
    super.key,
    required this.title,
    this.overline,
    this.badge,
    this.pageActions = const <AppTitleBarAction>[],
    this.leading = AppTitleBarLeading.back,
    this.leadingEnabled = true,
    this.onLeadingPressed,
    this.pinnedAction,
  });

  /// Ellipsised on one line; gets whatever width the actions leave.
  final String title;

  /// Optional small label above the title (project, ceremony, …).
  final AppTitleBarOverline? overline;

  /// Optional count beside the title (the Inbox's unprocessed count).
  final AppTitleBarBadge? badge;

  /// The screen's own actions, highest priority first.
  final List<AppTitleBarAction> pageActions;

  /// Drawer on the shell routes, back on pushed routes, none inside a
  /// ceremony.
  final AppTitleBarLeading leading;

  /// When false the leading affordance renders visually disabled
  /// (`onPressed: null`) rather than tappable — for screens that must gate the
  /// way out while a route transition is in flight (Clarify's `_routing`
  /// guard). Ignored when [leading] is [AppTitleBarLeading.none].
  final bool leadingEnabled;

  /// Overrides the leading's default behaviour (`Navigator.of(context).pop()`
  /// for back, `Scaffold.of(context).openDrawer()` for drawer) — for the
  /// screens whose way out is a `go` rather than a pop, or is guarded.
  final VoidCallback? onLeadingPressed;

  /// The reserved rightmost slot: capture (#458). Never overflows, identical
  /// position on every screen. `null` renders nothing and frees the slot.
  final AppTitleBarAction? pinnedAction;

  static const double _titleRowHeight = kToolbarHeight;
  static const double _overlineHeight = 20;

  static const Color _background = Colors.white;
  static const Color _titleColor = Color(0xFF1A1A2E);
  static const Color _overlineColor = Color(0xFF6B7280);
  static const Color _iconColor = Color(0xFF1A1A2E);
  static const Color _badgeBackground = Color(0xFFE5E7EB);
  static const Color _badgeForeground = Color(0xFF374151);

  @override
  Size get preferredSize => Size.fromHeight(
      _titleRowHeight + (overline != null ? _overlineHeight : 0));

  @override
  Widget build(BuildContext context) {
    final split = splitActions(
      budget: actionBudget(MediaQuery.sizeOf(context).width),
      actionCount: pageActions.length,
      hasPinned: pinnedAction != null,
    );
    final overflowed = pageActions.sublist(split.visible);

    return Material(
      color: _background,
      elevation: 0,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: preferredSize.height,
          child: Row(
            children: [
              _buildLeading(context),
              Expanded(child: _buildTitleBlock()),
              // Page actions ascend in priority towards the pinned slot.
              ...pageActions.take(split.visible).toList().reversed.map(
                    (action) => _buildActionButton(action),
                  ),
              if (pinnedAction != null) _buildActionButton(pinnedAction!),
              if (split.hasOverflow) _buildOverflowButton(overflowed),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeading(BuildContext context) {
    switch (leading) {
      case AppTitleBarLeading.none:
        return const SizedBox(width: 20);
      case AppTitleBarLeading.back:
        return IconButton(
          key: appTitleBarLeadingKey,
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: _iconColor),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: leadingEnabled
              ? (onLeadingPressed ?? () => Navigator.of(context).pop())
              : null,
        );
      case AppTitleBarLeading.drawer:
        return IconButton(
          key: appTitleBarLeadingKey,
          icon: const Icon(Icons.menu, color: _iconColor),
          tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
          // The bar lives in the Scaffold's own appBar slot, so this resolves
          // to the shell Scaffold — no root-ancestor lookup needed.
          onPressed: leadingEnabled
              ? (onLeadingPressed ?? () => Scaffold.of(context).openDrawer())
              : null,
        );
    }
  }

  Widget _buildTitleBlock() {
    final titleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: _titleColor,
            ),
          ),
        ),
        if (badge != null) _buildBadge(badge!),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (overline != null) _buildOverline(overline!),
          titleRow,
        ],
      ),
    );
  }

  Widget _buildOverline(AppTitleBarOverline overline) => SizedBox(
        height: _overlineHeight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (overline.icon != null) ...[
              Icon(overline.icon,
                  size: 14, color: overline.iconColor ?? _overlineColor),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                overline.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: _overlineColor,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _buildBadge(AppTitleBarBadge badge) => Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Container(
          key: appTitleBarBadgeKey,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: _badgeBackground,
            // 4px — the canonical small-meta radius (DESIGN.md § Roundedness).
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '${badge.count}',
            semanticsLabel: badge.semanticsLabel,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _badgeForeground,
            ),
          ),
        ),
      );

  Widget _buildActionButton(AppTitleBarAction action) => IconButton(
        key: action.key,
        icon: Icon(action.icon, color: action.color ?? _iconColor),
        tooltip: action.label,
        onPressed: action.onPressed,
      );

  Widget _buildOverflowButton(List<AppTitleBarAction> overflowed) =>
      PopupMenuButton<AppTitleBarAction>(
        key: appTitleBarOverflowKey,
        icon: const Icon(Icons.more_vert, color: _iconColor),
        onSelected: (action) => action.onPressed?.call(),
        itemBuilder: (context) => [
          for (final action in overflowed)
            PopupMenuItem<AppTitleBarAction>(
              key: action.key,
              value: action,
              enabled: action.onPressed != null,
              child: Row(
                children: [
                  Icon(action.icon, size: 20, color: action.color ?? _iconColor),
                  const SizedBox(width: 12),
                  Text(action.label),
                ],
              ),
            ),
        ],
      );
}

/// Keys the bar's own slots carry, so tests never depend on icon identity.
const Key appTitleBarLeadingKey = Key('app_title_bar_leading');
const Key appTitleBarOverflowKey = Key('app_title_bar_overflow');
const Key appTitleBarBadgeKey = Key('app_title_bar_badge');
