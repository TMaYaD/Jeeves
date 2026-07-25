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
/// The Inbox is the one screen that suppresses it — its `QuickAddBar` already
/// serves capture, so `AppShell` passes `null` on `/inbox` (owner ruling). The
/// [BuildContext] is the one `showCaptureSheet` opens the modal against.
AppTitleBarAction captureAction(BuildContext context) => AppTitleBarAction(
      key: const Key('capture_action'),
      icon: Icons.add,
      label: 'Capture',
      color: const Color(0xFF2563EB),
      onPressed: () => showCaptureSheet(context),
    );
