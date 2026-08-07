/// The global capture affordance (#458): the pinned title-bar action that
/// opens the [CaptureSheet] from any screen adopting [AppTitleBar].
library;

import 'package:flutter/material.dart';

import '../app_title_bar/app_title_bar.dart';
import 'capture_sheet.dart';

/// Builds the capture action for the bar's reserved rightmost `pinnedAction`
/// slot — never overflows, identical position on every screen that mounts it.
///
/// This is the single definition of the capture action: every call site hands
/// it to [AppTitleBar.pinnedAction] rather than re-declaring the icon, colour,
/// and key. Tapping it opens the stay-open [CaptureSheet]; the capture blue
/// `#2563EB` marks it as the standing call to action.
///
/// The glyph names capture's *destination* rather than a generic add: a tray
/// with an arrow going into it is literally Capture → Inbox. A plain `+` is
/// reserved for add-to-the-current-context actions, and the filled tray keeps
/// this act distinct from `Icons.inbox_outlined`, the Inbox as a place
/// (DESIGN.md § Icon vocabulary).
///
/// The Inbox is the one screen that suppresses it — its `QuickAddBar` already
/// serves capture, so `AppShell` passes `null` on `/inbox` (owner ruling). The
/// [BuildContext] is the one `showCaptureSheet` opens the modal against.
AppTitleBarAction captureAction(BuildContext context) => AppTitleBarAction(
      key: const Key('capture_action'),
      icon: Icons.move_to_inbox,
      label: 'Capture',
      color: const Color(0xFF2563EB),
      onPressed: () => showCaptureSheet(context),
    );
