import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/nudge_triggers.dart';
import 'package:jeeves/providers/system_trust_provider.dart';
import 'package:jeeves/widgets/nudge_banner.dart';

class _RecordingNudgeActions extends NudgeActions {
  // Use the super-parameter shorthand to forward the positional Ref to
  // NudgeActions(this._ref). The `use_super_parameters` lint enforces this
  // form; an earlier CodeRabbit review flagged it as unsound, but that
  // claim was incorrect — Dart binds super.ref to the matching positional
  // super parameter by position, and CI proves the form works.
  _RecordingNudgeActions(super.ref, {required this.onDismiss});
  final void Function(RitualId) onDismiss;

  @override
  Future<void> dismiss(RitualId ritual) async => onDismiss(ritual);
}

GoRouter _router() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: NudgeBanner()),
        ),
        GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const Scaffold(body: Text('planning')),
        ),
        GoRoute(
          path: '/shutdown',
          builder: (_, _) => const Scaffold(body: Text('shutdown')),
        ),
        GoRoute(
          path: '/periodic-review',
          builder: (_, _) => const Scaffold(body: Text('review')),
        ),
      ],
    );

void main() {
  group('NudgeBanner', () {
    testWidgets('renders nothing when the queue is empty', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          nudgeQueueProvider.overrideWith((ref) => const <RitualId>[]),
          nudgeBannerEnabledProvider.overrideWith((ref, r) => true),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ));
      await tester.pump();
      expect(find.byKey(const Key('planning_banner_visible')), findsNothing);
      expect(find.byKey(const Key('shutdown_banner_visible')), findsNothing);
      expect(
        find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing,
      );
    });

    testWidgets('renders the queue head when its banner is enabled',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          nudgeQueueProvider.overrideWith(
            (ref) => const [RitualId.dailyPlanning, RitualId.eveningShutdown],
          ),
          nudgeBannerEnabledProvider.overrideWith((ref, r) => true),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ));
      await tester.pump();
      expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);
      expect(find.byKey(const Key('shutdown_banner_visible')), findsNothing);
    });

    testWidgets(
        'skips the head and renders the next visible Ritual whose banner is enabled',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          nudgeQueueProvider.overrideWith(
            (ref) => const [RitualId.weeklyReview, RitualId.dailyPlanning],
          ),
          nudgeBannerEnabledProvider.overrideWith(
            (ref, r) => r != RitualId.weeklyReview,
          ),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ));
      await tester.pump();
      expect(
        find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing,
      );
      expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);
    });

    testWidgets('a horizontal swipe calls NudgeActions.dismiss with the right Ritual',
        (tester) async {
      RitualId? dismissed;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          nudgeQueueProvider
              .overrideWith((ref) => const [RitualId.eveningShutdown]),
          nudgeBannerEnabledProvider.overrideWith((ref, r) => true),
          nudgeActionsProvider.overrideWith(
            (ref) => _RecordingNudgeActions(
              ref,
              onDismiss: (r) => dismissed = r,
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ));
      await tester.pump();
      await tester.drag(
          find.byKey(const Key('shutdown_banner_visible')), const Offset(-200, 0));
      // The banner's pulse animation `repeat(reverse: true)` runs forever, so
      // `pumpAndSettle` never returns. One frame is enough to flush the drag.
      await tester.pump();
      expect(dismissed, RitualId.eveningShutdown);
    });

    testWidgets('a short drag does not dismiss', (tester) async {
      RitualId? dismissed;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          nudgeQueueProvider
              .overrideWith((ref) => const [RitualId.dailyPlanning]),
          nudgeBannerEnabledProvider.overrideWith((ref, r) => true),
          nudgeActionsProvider.overrideWith(
            (ref) => _RecordingNudgeActions(
              ref,
              onDismiss: (r) => dismissed = r,
            ),
          ),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ));
      await tester.pump();
      await tester.drag(
          find.byKey(const Key('planning_banner_visible')), const Offset(20, 0));
      await tester.pump();
      expect(dismissed, isNull);
    });

    for (final ritual in RitualId.values) {
      testWidgets('${ritual.name} Banner has no ✕ and a 2px button',
          (tester) async {
        await tester.pumpWidget(ProviderScope(
          overrides: [
            nudgeQueueProvider.overrideWith((ref) => [ritual]),
            nudgeBannerEnabledProvider.overrideWith((ref, r) => true),
            weeklyReviewDaysLateProvider.overrideWith((ref) => 0),
            unfinishedReviewTriggerProvider
                .overrideWith((ref) => TriggerState.idle),
          ],
          child: MaterialApp.router(routerConfig: _router()),
        ));
        await tester.pump();
        expect(find.byIcon(Icons.close), findsNothing);
        final button = tester
            .widgetList<Material>(find.descendant(
                of: find.byType(NudgeBanner), matching: find.byType(Material)))
            .where((m) => m.borderRadius == BorderRadius.circular(2));
        expect(button, hasLength(1));
      });
    }
  });

  group('Weekly Review copy', () {
    Future<void> pumpWeeklyReview(
      WidgetTester tester, {
      required int? daysLate,
      bool unfinished = false,
    }) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          nudgeQueueProvider.overrideWith((ref) => const [RitualId.weeklyReview]),
          nudgeBannerEnabledProvider.overrideWith((ref, r) => true),
          weeklyReviewDaysLateProvider.overrideWith((ref) => daysLate),
          unfinishedReviewTriggerProvider.overrideWith((ref) => unfinished
              ? TriggerState(isFiring: true, firingSince: DateTime(2026, 5, 20))
              : TriggerState.idle),
        ],
        child: MaterialApp.router(routerConfig: _router()),
      ));
      await tester.pump();
    }

    test('first line carries the days late: words to nine, digits from ten', () {
      expect(weeklyReviewFirstLine(0), 'The Weekly Review is due, sir.');
      expect(weeklyReviewFirstLine(1), 'The Weekly Review, sir. One day late.');
      expect(
          weeklyReviewFirstLine(3), 'The Weekly Review, sir. Three days late.');
      expect(
          weeklyReviewFirstLine(9), 'The Weekly Review, sir. Nine days late.');
      expect(weeklyReviewFirstLine(10), 'The Weekly Review, sir. 10 days late.');
      expect(weeklyReviewFirstLine(12), 'The Weekly Review, sir. 12 days late.');
    });

    testWidgets('a due review shows the days late and a Bertie button',
        (tester) async {
      await pumpWeeklyReview(tester, daysLate: 3);
      expect(find.text('The Weekly Review, sir. Three days late.'),
          findsOneWidget);
      expect(find.text('Start Weekly Review'), findsNothing);
      expect(
          find.textContaining(RegExp(r'^(Right ho|Very good|At once|Indeed)')),
          findsOneWidget);
    });

    testWidgets('an unfinished review uses the continue wording',
        (tester) async {
      await pumpWeeklyReview(tester, daysLate: null, unfinished: true);
      expect(find.text('The Weekly Review, sir. Unfinished.'), findsOneWidget);
      expect(find.text('Push on  →'), findsOneWidget);
    });

    testWidgets('unfinished wins over days late', (tester) async {
      await pumpWeeklyReview(tester, daysLate: 12, unfinished: true);
      expect(find.text('The Weekly Review, sir. Unfinished.'), findsOneWidget);
      expect(find.textContaining('12 days late'), findsNothing);
    });

    testWidgets('only the content-state Trigger firing is not "late"',
        (tester) async {
      await pumpWeeklyReview(tester, daysLate: null);
      expect(find.textContaining('late.'), findsNothing);
      expect(find.textContaining('Unfinished'), findsNothing);
    });
  });
}
