import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/providers/focus_session_planning_provider.dart';

/// Drives a page transition to completion in real time while draining the
/// drift-stream snapshot load the newly-visible step triggers on entry.
///
/// A plain `pumpAndSettle` hangs here: Clarify Inbox loads its snapshot via a
/// real-async drift `.first` that only fires once the step is visible (after
/// the 300 ms transition), and fake-async `pumpAndSettle` cannot complete that
/// real-async read — its loading spinner would spin forever. So advance the
/// clock in real steps, draining the real event queue between each.
///
/// Shared by `focus_session_planning_footer_test.dart` and
/// `focus_session_planning_back_test.dart` — previously defined verbatim in
/// both (#486 review).
Future<void> settleAcrossTransition(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// Every performance now opens on the duration-estimate intro (#486, step 0).
/// Cross into Clarify Inbox (step 1) before exercising the working-step
/// footer/back contracts.
///
/// Shared by `focus_session_planning_footer_test.dart` and
/// `focus_session_planning_back_test.dart` — previously defined verbatim in
/// both (#486 review).
Future<void> advancePastIntro(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await container.read(focusSessionPlanningProvider.notifier).advanceStep();
  await settleAcrossTransition(tester);
}
