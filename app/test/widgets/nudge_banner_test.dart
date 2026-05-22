import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/widgets/nudge_banner.dart';

class _RecordingNudgeActions extends NudgeActions {
  _RecordingNudgeActions(super.ref, {required this.onDismiss});
  final void Function(RitualId) onDismiss;

  @override
  Future<void> dismiss(RitualId ritual) async => onDismiss(ritual);
}

Widget _wrap({
  required List<Override> overrides,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const Scaffold(body: NudgeBanner()),
      ),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, __) => const Scaffold(body: Text('planning')),
      ),
      GoRoute(
        path: '/shutdown',
        builder: (_, __) => const Scaffold(body: Text('shutdown')),
      ),
      GoRoute(
        path: '/periodic-review',
        builder: (_, __) => const Scaffold(body: Text('review')),
      ),
    ],
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  group('NudgeBanner', () {
    testWidgets('renders nothing when the queue is empty', (tester) async {
      await tester.pumpWidget(_wrap(
        overrides: [
          nudgeQueueProvider.overrideWith((ref) => const <RitualId>[]),
          nudgeBannerEnabledProvider.overrideWith((ref, r) => true),
        ],
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
      await tester.pumpWidget(_wrap(
        overrides: [
          nudgeQueueProvider.overrideWith(
            (ref) => const [RitualId.dailyPlanning, RitualId.eveningShutdown],
          ),
          nudgeBannerEnabledProvider.overrideWith((ref, r) => true),
        ],
      ));
      await tester.pump();
      expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);
      expect(find.byKey(const Key('shutdown_banner_visible')), findsNothing);
    });

    testWidgets(
        'skips the head and renders the next visible Ritual whose banner is enabled',
        (tester) async {
      await tester.pumpWidget(_wrap(
        overrides: [
          nudgeQueueProvider.overrideWith(
            (ref) => const [RitualId.weeklyReview, RitualId.dailyPlanning],
          ),
          nudgeBannerEnabledProvider.overrideWith(
            (ref, r) => r != RitualId.weeklyReview,
          ),
        ],
      ));
      await tester.pump();
      expect(
        find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing,
      );
      expect(find.byKey(const Key('planning_banner_visible')), findsOneWidget);
    });

    testWidgets('dismiss button calls NudgeActions.dismiss with the right Ritual',
        (tester) async {
      RitualId? dismissed;
      await tester.pumpWidget(_wrap(
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
      ));
      await tester.pump();
      await tester.tap(find.byKey(const Key('shutdown_banner_dismiss')));
      await tester.pumpAndSettle();
      expect(dismissed, RitualId.eveningShutdown);
    });
  });
}
