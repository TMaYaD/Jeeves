import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/onboarding_provider.dart';
import 'package:jeeves/providers/periodic_review_settings_provider.dart';
import 'package:jeeves/widgets/periodic_review_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

Todo _fakeTodo() => Todo(
      id: 'fake-id',
      title: 'Fake Todo',
      notes: null,
      doneAt: null,
      priority: null,
      dueDate: null,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: null,
      clarified: false,
      intent: 'next',
      timeEstimate: null,
      energyLevel: null,
      captureSource: 'manual',
      locationId: null,
      userId: 'local',
      timeSpentMinutes: 0,
    );

Widget _buildBanner({
  required bool isDue,
  required bool dismissed,
  required bool bannerEnabled,
  Stream<bool>? hasTodosStream,
  Stream<List<Todo>>? inboxStream,
  Stream<List<Todo>>? nextStream,
  Stream<List<Todo>>? waitingStream,
  Stream<List<Todo>>? maybeStream,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          body: Column(
            children: [
              const PeriodicReviewBanner(),
              Expanded(child: child),
            ],
          ),
        ),
        routes: [
          GoRoute(path: '/', builder: (_, _) => const Text('home')),
        ],
      ),
      GoRoute(
        path: '/periodic-review',
        builder: (_, _) => const Scaffold(body: Text('weekly review')),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      periodicReviewBannerEnabledProvider.overrideWith((_) => bannerEnabled),
      periodicReviewIsDueProvider.overrideWith((_) => isDue),
      periodicReviewBannerDismissedTodayProvider.overrideWith((_) => dismissed),
      hasTodosProvider.overrideWith(
          (ref) => hasTodosStream ?? Stream.value(true)),
      unfilteredInboxProvider.overrideWith(
          (ref) => inboxStream ?? Stream.value([_fakeTodo()])),
      unfilteredNextActionsProvider.overrideWith(
          (ref) => nextStream ?? Stream.value([])),
      unfilteredWaitingForProvider.overrideWith(
          (ref) => waitingStream ?? Stream.value([])),
      unfilteredMaybeProvider.overrideWith(
          (ref) => maybeStream ?? Stream.value([])),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> _pumpBanner(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pump();
  await tester.pump();
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('banner visible when due and not dismissed', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: true,
        dismissed: false,
        bannerEnabled: true,
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsOneWidget);
  });

  testWidgets('banner hidden when not due', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: false,
        dismissed: false,
        bannerEnabled: true,
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets('banner hidden when dismissed today', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: true,
        dismissed: true,
        bannerEnabled: true,
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets('banner hidden when bannerEnabled is false', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: true,
        dismissed: false,
        bannerEnabled: false,
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets('banner hidden when no todos exist', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: true,
        dismissed: false,
        bannerEnabled: true,
        hasTodosStream: Stream.value(false),
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets('banner hidden while hasTodosProvider is loading',
      (tester) async {
    await tester.pumpWidget(_buildBanner(
      isDue: true,
      dismissed: false,
      bannerEnabled: true,
      hasTodosStream: const Stream<bool>.empty(),
    ));
    await tester.pump();
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets('tapping banner navigates to /periodic-review', (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: true,
        dismissed: false,
        bannerEnabled: true,
      ),
    );

    await tester.tap(find.byKey(const Key('periodic_review_banner_visible')));
    await tester.pumpAndSettle();

    expect(find.text('weekly review'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // Empty-actionable trigger (issue #259)
  // ---------------------------------------------------------------------------

  testWidgets(
      'banner visible when inbox+next empty and waiting non-empty (not due)',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: false,
        dismissed: false,
        bannerEnabled: true,
        inboxStream: Stream.value([]),
        nextStream: Stream.value([]),
        waitingStream: Stream.value([_fakeTodo()]),
        maybeStream: Stream.value([]),
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsOneWidget);
  });

  testWidgets(
      'banner visible when inbox+next empty and maybe non-empty (not due)',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: false,
        dismissed: false,
        bannerEnabled: true,
        inboxStream: Stream.value([]),
        nextStream: Stream.value([]),
        waitingStream: Stream.value([]),
        maybeStream: Stream.value([_fakeTodo()]),
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsOneWidget);
  });

  testWidgets(
      'banner hidden when inbox+next empty and waiting+maybe also empty',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: false,
        dismissed: false,
        bannerEnabled: true,
        inboxStream: Stream.value([]),
        nextStream: Stream.value([]),
        waitingStream: Stream.value([]),
        maybeStream: Stream.value([]),
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets(
      'banner hidden when inbox non-empty even with waiting/maybe non-empty (not due)',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: false,
        dismissed: false,
        bannerEnabled: true,
        inboxStream: Stream.value([_fakeTodo()]),
        nextStream: Stream.value([]),
        waitingStream: Stream.value([_fakeTodo()]),
        maybeStream: Stream.value([_fakeTodo()]),
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets(
      'banner hidden when next non-empty even with waiting/maybe non-empty (not due)',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: false,
        dismissed: false,
        bannerEnabled: true,
        inboxStream: Stream.value([]),
        nextStream: Stream.value([_fakeTodo()]),
        waitingStream: Stream.value([_fakeTodo()]),
        maybeStream: Stream.value([_fakeTodo()]),
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets(
      'banner hidden when dismissed today, even under empty-actionable trigger',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: false,
        dismissed: true,
        bannerEnabled: true,
        inboxStream: Stream.value([]),
        nextStream: Stream.value([]),
        waitingStream: Stream.value([_fakeTodo()]),
        maybeStream: Stream.value([]),
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets(
      'banner hidden when bannerEnabled is false, even under empty-actionable trigger',
      (tester) async {
    await _pumpBanner(
      tester,
      _buildBanner(
        isDue: false,
        dismissed: false,
        bannerEnabled: false,
        inboxStream: Stream.value([]),
        nextStream: Stream.value([]),
        waitingStream: Stream.value([_fakeTodo()]),
        maybeStream: Stream.value([]),
      ),
    );
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });

  testWidgets('banner hidden while a list stream is still loading',
      (tester) async {
    await tester.pumpWidget(_buildBanner(
      isDue: false,
      dismissed: false,
      bannerEnabled: true,
      inboxStream: Stream.value([]),
      nextStream: Stream.value([]),
      waitingStream: const Stream<List<Todo>>.empty(),
      maybeStream: Stream.value([_fakeTodo()]),
    ));
    await tester.pump();
    expect(find.byKey(const Key('periodic_review_banner_visible')),
        findsNothing);
  });
}
