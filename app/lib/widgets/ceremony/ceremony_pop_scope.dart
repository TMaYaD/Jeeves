/// Ceremony back-navigation contract (issue #180).
///
/// Ceremony screens are top-level routes outside the [ShellRoute], entered
/// via stackless navigation (`context.go`, notification deep-links, the
/// nudge banner), so there is no in-app back stack to pop into. This wrapper
/// gives system back well-defined semantics, uniform across all three
/// Ceremonies and every launch path:
///
/// - **System back mirrors the footer `Back` affordance** — it invokes the
///   exact callback the active step's footer holds (retreating the per-item
///   cursor first, then the step). While inside the wizard the performance
///   stays in-progress.
/// - **When footer Back is unavailable** (step 0 / first item, or a
///   completion screen) system back exits the ceremony to the execution
///   home screen (`/focus`, user-titled "Now") — never to the launcher.
///   Exiting mid-ceremony abandons the performance: the screen's dispose
///   fires `CeremonyInProgressNotifier.exit()`, and Triggers
///   treat it as if the performance hadn't happened.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Route of the execution home screen — the uniform ceremony exit target.
const String kCeremonyExitRoute = '/focus';

class CeremonyPopScope extends StatelessWidget {
  const CeremonyPopScope({
    super.key,
    required this.onBack,
    required this.child,
  });

  /// The active step's Back callback — the same callback the step's footer
  /// renders. Null when footer Back is unavailable; system back then exits
  /// the ceremony to [kCeremonyExitRoute].
  final VoidCallback? onBack;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final back = onBack;
        if (back != null) {
          back();
        } else {
          context.go(kCeremonyExitRoute);
        }
      },
      child: child,
    );
  }
}
