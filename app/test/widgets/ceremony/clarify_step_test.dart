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

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/tags_provider.dart';
import 'package:jeeves/providers/task_detail_provider.dart';
import 'package:jeeves/utils/snapshot_nav.dart';
import 'package:jeeves/widgets/ceremony/clarify_step.dart';
import 'package:jeeves/widgets/clarify_retention.dart';
import 'package:jeeves/widgets/process_to_handlers.dart';

import '../../test_helpers.dart';

/// Minimal provider scope so the widget tree can build without crashing
/// on providers that ClarifyCard might read inside ProviderScope.
Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  setUpAll(configureSqliteForTests);

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

  // The cursor-retreat path, which no card-level test reaches: ClarifyStep
  // keys each ClarifyCard by Capture id, so stepping back to the previous item
  // builds a *different* card and disposes the one that held the typing. A
  // retention store that looked healthy in every card test could still be dead
  // here.
  group('ClarifyStep \u2014 retention across the item cursor', () {
    late GtdDatabase db;

    setUp(() async {
      db = GtdDatabase(NativeDatabase.memory());
      for (final (id, title) in [('c1', 'Buy milk'), ('c2', 'Call Bob')]) {
        await db.captureDao.insertCapture(CapturesCompanion(
          id: Value(id),
          title: Value(title),
          captureSource: const Value('manual'),
          userId: const Value('local'),
          createdAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ));
      }
    });
    tearDown(() async => db.close());

    /// The step at [index] of a two-item inbox snapshot.
    ///
    /// Every provider the inner card reads is fed a single-value stream:
    /// a real drift `watch()` leaves a pending timer behind and hangs
    /// `pumpAndSettle` (docs/TESTING.md).
    Widget stepAt(
      int index,
      ClarifyRetention retention, {
      Future<void> Function(ProcessAction)? onAfterRoute,
    }) =>
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            for (final id in ['c1', 'c2'])
              captureProvider(id).overrideWith(
                (_) => Stream.fromFuture(db.captureDao.getCapture(id)),
              ),
            for (final id in ['c1', 'c2'])
              captureTagHintsProvider(id)
                  .overrideWith((_) => Stream.value(const <Tag>[])),
            personTagsProvider.overrideWith((_) => Stream.value(const <Tag>[])),
            contextTagsProvider
                .overrideWith((_) => Stream.value(const <Tag>[])),
            projectTagsProvider
                .overrideWith((_) => Stream.value(const <Tag>[])),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: ClarifyStep(
                nav: SnapshotNav<String>(items: const ['c1', 'c2'],
                    index: index),
                routings: const {},
                onAfterRoute: onAfterRoute ?? (_) async {},
                retention: retention,
              ),
            ),
          ),
        );

    Future<void> pumpFrames(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    String titleText(WidgetTester tester) =>
        tester
            .widget<TextField>(find.byKey(const Key('clarify_title')))
            .controller
            ?.text ??
        '';

    testWidgets('typing on the first item survives advancing and retreating',
        (tester) async {
      final retention = ClarifyRetention();

      await tester.pumpWidget(stepAt(0, retention));
      await pumpFrames(tester);
      expect(titleText(tester), 'Buy milk');

      await tester.enterText(
          find.byKey(const Key('clarify_title')), 'Buy oat milk');
      await tester.pump();

      // Advance: a new ValueKey, so the first card is disposed outright.
      await tester.pumpWidget(stepAt(1, retention));
      await pumpFrames(tester);
      expect(titleText(tester), 'Call Bob',
          reason: 'the second item must render its own Capture, or the '
              'retreat below proves nothing');

      await tester.pumpWidget(stepAt(0, retention));
      await pumpFrames(tester);

      expect(titleText(tester), 'Buy oat milk');
      // …and the Capture itself is still untouched (ADR-0023).
      expect((await db.captureDao.getCapture('c1'))!.title, 'Buy milk');
    });

    testWidgets('each item keeps its own draft', (tester) async {
      final retention = ClarifyRetention();

      await tester.pumpWidget(stepAt(0, retention));
      await pumpFrames(tester);
      await tester.enterText(
          find.byKey(const Key('clarify_title')), 'Buy oat milk');
      await tester.pump();

      await tester.pumpWidget(stepAt(1, retention));
      await pumpFrames(tester);
      await tester.enterText(
          find.byKey(const Key('clarify_title')), 'Call Bob back');
      await tester.pump();

      await tester.pumpWidget(stepAt(0, retention));
      await pumpFrames(tester);
      expect(titleText(tester), 'Buy oat milk');

      await tester.pumpWidget(stepAt(1, retention));
      await pumpFrames(tester);
      expect(titleText(tester), 'Call Bob back');
    });

    // The host half of #689. `InboxClarificationStep` records a routing and
    // advances the cursor from this hook, so what the hook says has to be
    // true of the database: before the dialog reached a Capture surface,
    // a route that wrote nothing would still have advanced the ceremony and
    // recorded `nextAction` for an item left sitting in the Inbox.
    group('the dialog-mediated route reaches the host exactly once', () {
      Future<void> tapInCard(WidgetTester tester, String label) async {
        for (var i = 0; i < 15 && find.text(label).evaluate().isEmpty; i++) {
          await tester.drag(
              find.byType(Scrollable).first, const Offset(0, -200));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(find.text(label), findsOneWidget);
        await tester.ensureVisible(find.text(label));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text(label));
        await tester.pump(const Duration(milliseconds: 50));
      }

      testWidgets('Save advances the cursor over a Capture that really left',
          (tester) async {
        final fired = <ProcessAction>[];
        await tester.pumpWidget(stepAt(0, ClarifyRetention(),
            onAfterRoute: (a) async => fired.add(a)));
        await pumpFrames(tester);

        await tapInCard(tester, 'Next Action');
        await pumpFrames(tester);
        await tapInCard(tester, 'Save');
        await pumpFrames(tester);

        // One hook, carrying the modifier — which `toRoutingKind()` collapses
        // onto `nextAction`, the destination that actually landed.
        expect(fired, [ProcessAction.nextActionDialog]);
        expect(fired.single.toRoutingKind(), RoutingKind.nextAction);
        // …and the row the record describes exists.
        final outcomeIds = await db.captureDao.outcomeIdsForCapture('c1');
        expect(outcomeIds, hasLength(1));
        expect((await db.todoDao.getTodo(outcomeIds.single))?.intent, 'next');
        expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNotNull);
      });

      testWidgets('Cancel neither advances nor records', (tester) async {
        final fired = <ProcessAction>[];
        await tester.pumpWidget(stepAt(0, ClarifyRetention(),
            onAfterRoute: (a) async => fired.add(a)));
        await pumpFrames(tester);

        await tapInCard(tester, 'Next Action');
        await pumpFrames(tester);
        await tapInCard(tester, 'Cancel');
        await pumpFrames(tester);

        expect(fired, isEmpty,
            reason: 'cancel leaves the item unresolved, so the '
                'ceremony must stay on it');
        expect(await db.captureDao.outcomeIdsForCapture('c1'), isEmpty);
        expect((await db.captureDao.getCapture('c1'))!.clarifiedAt, isNull);
      });
    });
  });
}
