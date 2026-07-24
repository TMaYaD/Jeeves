/// Widget tests for [ClarifyStep] — the shared "Clarify Inbox" step body
/// used by both the Daily Planning Ritual and the Weekly Review.
///
/// These tests exercise the loading and completion branches of [ClarifyStep]
/// without needing a real database or Riverpod provider — the per-item branch
/// is covered by [ClarifyCard]'s own test suite. The test harness uses a
/// no-op provider scope so the widget can render without crashing, verifying:
///
/// 1. The loading branch (spinner) is shown while [nav] is not loaded.
/// 2. The canonical "Inbox is clear" completion widget is shown once
///    [nav.isComplete] or [nav.isEmpty].
/// 3. [onLoad] is called once on the first frame when the snapshot is not yet
///    loaded.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/utils/snapshot_nav.dart';
import 'package:jeeves/widgets/ceremony/clarify_step.dart';

/// Minimal provider scope so the widget tree can build without crashing
/// on providers that ClarifyCard might read inside ProviderScope.
Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  group('ClarifyStep — loading branch', () {
    testWidgets('shows CircularProgressIndicator while nav is not loaded',
        (tester) async {
      await tester.pumpWidget(_wrap(ClarifyStep(
        nav: const SnapshotNav<String>(),
        routings: const {},
        onAfterRoute: (_) async {},
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
      )));
      await tester.pumpAndSettle();

      expect(find.text('Inbox is clear'), findsOneWidget);
    });
  });
}
