/// The global capture FAB (#458) — one persistent affordance that opens the
/// [CaptureSheet] from any screen.
///
/// GTD's "capture from anywhere, zero friction" tenet: a thought that occurs
/// while the user is reviewing Next Actions, mid-ceremony, or on a task detail
/// should be recordable on the spot, without navigating to the Inbox first.
///
/// Capture is one concept app-wide, so the FAB keeps one identity regardless of
/// the host screen's accent: the primary blue `#2563EB`. It is a **genuine
/// circle** — explicitly the surviving circular case under DESIGN.md's radii
/// ruling ("only genuine circles … stay circular").
///
/// [heroTag] is disabled (`null`): the same FAB renders on many routes, and a
/// shared default hero tag would collide across a route transition when two
/// scaffolds' FABs momentarily coexist. Capture needs no hero flight.
library;

import 'package:flutter/material.dart';

import 'capture_sheet.dart';

class CaptureFab extends StatelessWidget {
  const CaptureFab({super.key});

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      key: const Key('capture_fab'),
      heroTag: null,
      backgroundColor: const Color(0xFF2563EB),
      foregroundColor: Colors.white,
      shape: const CircleBorder(),
      tooltip: 'Capture',
      onPressed: () => showCaptureSheet(context),
      child: const Icon(Icons.add),
    );
  }
}
