/// Widget tests for [ClarifyStep] — the shared "Clarify Inbox" step body
/// used by both the Daily Planning Ritual and the Weekly Review.
///
/// Most of these exercise the loading and completion branches of [ClarifyStep]
/// without needing a real database or Riverpod provider — the per-item card's
/// own behaviour is covered by [ClarifyCard]'s test suite. The exception is
/// the missing-subject escape, which is a wiring contract *between* the two
/// and so has to be driven through a real card. The harness otherwise uses a
/// no-op provider scope so the widget can render without crashing, verifying:
///
/// 1. The loading branch (spinner) is shown while [nav] is not loaded.
/// 2. The canonical "Inbox is clear" completion widget is shown once
///    [nav.isComplete] or [nav.isEmpty].
/// 3. [onLoad] is called once on the first frame when the snapshot is not yet
///    loaded.
/// 4. The widget is a plain [StatelessWidget] that accepts ceremony-specific
///    state without hard-coding any provider dependency.
/// 5. Both DPR and WR pass [Map<int, RoutingKind>] directly (no ceremony-
///    specific projection).
/// 6. A card whose Capture was hard-deleted renders the missing panel, and its
///    escape reaches `onSubjectMissing` exactly once (#428).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/utils/snapshot_nav.dart';
import 'package:jeeves/widgets/ceremony/clarify_step.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

/// Minimal provider scope so the widget tree can build without crashing
/// on providers that ClarifyCard might read inside ProviderScope.
Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  group('ClarifyStep — the per-item card lost its subject (#428)', () {
    testWidgets('the escape reaches the ceremony, and fires exactly once',
        (tester) async {
      // The other groups here stub `onSubjectMissing` to a no-op because they
      // exercise the loading/completion branches, where no card is built. This
      // one drives the wiring itself: a Capture that is already gone renders
      // the missing panel, and its CTA is what advances the ceremony cursor.
      // Nothing else in the suite covers that the callback is actually
      // reachable from a ClarifyStep — only that the hosts pass one.
      var escaped = 0;

      await tester.pumpWidget(ProviderScope(
        overrides: [
          // `AsyncData(null)` — the Capture was hard-deleted. Only the missing
          // branch renders, so the card never reaches the providers its data
          // branch would read.
          captureProvider('cap1')
              .overrideWith((_) => Stream<Capture?>.value(null)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ClarifyStep(
              nav: const SnapshotNav<String>(items: ['cap1']),
              routings: const {},
              onAfterRoute: (_) async {},
              onSubjectMissing: () => escaped++,
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('This item is no longer in your Inbox'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // Two taps in the window before the cursor advance rebuilds the step:
      // firing twice would skip an extra inbox item.
      await tester.tap(find.text('Continue'));
      await tester.tap(find.text('Continue'));
      await tester.pump();

      expect(escaped, 1);
    });
  });

  group('ClarifyStep — loading branch', () {
    testWidgets('shows CircularProgressIndicator while nav is not loaded',
        (tester) async {
      await tester.pumpWidget(_wrap(ClarifyStep(
        nav: const SnapshotNav<String>(),
        routings: const {},
        onAfterRoute: (_) async {},
        onSubjectMissing: () {},
      )));
      // pump (not pumpAndSettle) — the default spinner is animated, so
      // pumpAndSettle would time out waiting for it to stop.
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Inbox is clear'), findsNothing);
    });

    testWidgets('calls onLoad once on the first unloaded frame', (tester) async {
      var loadCalls = 0;
      await tester.pumpWidget(_wrap(ClarifyStep(
        nav: const SnapshotNav<String>(),
        routings: const {},
        onAfterRoute: (_) async {},
        onSubjectMissing: () {},
        onLoad: () => loadCalls++,
      )));
      await tester.pump();

      expect(loadCalls, 1);
    });
  });

  group('ClarifyStep — completion branch', () {
    testWidgets('shows canonical completion widget when nav.isEmpty',
        (tester) async {
      final emptyNav = SnapshotNav<String>(items: [], index: 0);
      await tester.pumpWidget(_wrap(ClarifyStep(
        nav: emptyNav,
        routings: const {},
        onAfterRoute: (_) async {},
        onSubjectMissing: () {},
      )));
      await tester.pumpAndSettle();

      // Both ceremonies show the same hardcoded "Inbox is clear" frame.
      // The line stands alone — no subtitle (dropped in c002900 because
      // the wizard footer already tells the user what to do next).
      expect(find.text('Inbox is clear'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('shows canonical completion widget when nav.isComplete',
        (tester) async {
      // One item, cursor at index 1 (past the end) → isComplete.
      final completeNav = SnapshotNav<String>(items: ['id1'], index: 1);
      await tester.pumpWidget(_wrap(ClarifyStep(
        nav: completeNav,
        routings: const {},
        onAfterRoute: (_) async {},
        onSubjectMissing: () {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Inbox is clear'), findsOneWidget);
    });
  });

  group('ClarifyStep — shared usage contract', () {
    testWidgets(
        'accepts a RoutingKind routings map — both DPR and WR pass '
        'Map<int, RoutingKind> directly with no per-ceremony projection',
        (tester) async {
      // Both ceremonies pass Map<int, RoutingKind> directly to ClarifyStep.
      // This test verifies the type is accepted without runtime error.
      final routings = <int, RoutingKind>{
        0: RoutingKind.nextAction,
        1: RoutingKind.maybe,
      };
      final completeNav = SnapshotNav<String>(items: ['id1', 'id2'], index: 2);
      await tester.pumpWidget(_wrap(ClarifyStep(
        nav: completeNav,
        routings: routings,
        onAfterRoute: (_) async {},
        onSubjectMissing: () {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Inbox is clear'), findsOneWidget);
    });

    testWidgets('onAfterRoute callback is typed to Future<void> Function(ProcessAction)',
        (tester) async {
      // Verify the widget compiles and renders when a Future<void>-returning
      // ProcessAction callback is provided — both DPR and WR supply this shape.
      ProcessAction? captured;
      final completeNav = SnapshotNav<String>(items: [], index: 0);
      await tester.pumpWidget(_wrap(ClarifyStep(
        nav: completeNav,
        routings: const {},
        onAfterRoute: (action) async => captured = action,
        onSubjectMissing: () {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Inbox is clear'), findsOneWidget);
      // The callback is wired but not invoked (no item to tap) — just ensure
      // the captured reference remains null, confirming the callback type
      // doesn't cause a compile or runtime error.
      expect(captured, isNull);
    });
  });
}
