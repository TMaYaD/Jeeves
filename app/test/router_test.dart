/// Tests for the production router's redirect policy (issue #225).
///
/// /focus must be unconditionally accessible regardless of
/// focusSessionPlanningCompletionNotifier.value. Planning is entered
/// explicitly via the Focus screen's "Plan the Day" button or the
/// AppShell planning banner — never via an automatic redirect.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/router.dart' show appRouterRedirect;
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

// Uses the production redirect function with stub routes so that any future
// regression (e.g. re-adding a /focus guard) is caught here.
GoRouter _buildRouter() => GoRouter(
      initialLocation: '/inbox',
      redirect: appRouterRedirect,
      routes: [
        GoRoute(
          path: '/inbox',
          builder: (_, _) => const Scaffold(body: Text('inbox')),
        ),
        GoRoute(
          path: '/focus',
          builder: (_, _) => const Scaffold(body: Text('focus')),
        ),
        GoRoute(
          path: '/focus-session-planning',
          builder: (_, _) => const Scaffold(body: Text('planning')),
        ),
      ],
    );

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    focusSessionPlanningCompletionNotifier.value = false;
    focusSessionPlanningBannerDismissedNotifier.value = false;
  });

  testWidgets(
      '/focus is accessible when planning is incomplete (no auto-redirect)',
      (tester) async {
    focusSessionPlanningCompletionNotifier.value = false;
    final router = _buildRouter();

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    router.go('/focus');
    await tester.pumpAndSettle();

    expect(find.text('focus'), findsOneWidget);
    expect(find.text('planning'), findsNothing);
  });

  testWidgets('/focus is accessible when planning is complete', (tester) async {
    focusSessionPlanningCompletionNotifier.value = true;
    final router = _buildRouter();

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    router.go('/focus');
    await tester.pumpAndSettle();

    expect(find.text('focus'), findsOneWidget);
    expect(find.text('planning'), findsNothing);
  });

  testWidgets('/focus-session-planning is still reachable explicitly',
      (tester) async {
    final router = _buildRouter();

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    router.go('/focus-session-planning');
    await tester.pumpAndSettle();

    expect(find.text('planning'), findsOneWidget);
    expect(find.text('focus'), findsNothing);
  });
}
