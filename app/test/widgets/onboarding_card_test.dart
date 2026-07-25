import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/onboarding_provider.dart';
import 'package:jeeves/widgets/onboarding_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

Widget _buildCard(Stream<bool> hasTodosStream, {int? greetingSeed}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: SingleChildScrollView(
            child: OnboardingCard(greetingSeed: greetingSeed),
          ),
        ),
      ),
      GoRoute(
        path: '/import',
        builder: (_, _) => const Scaffold(body: Text('import screen')),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => const Scaffold(body: Text('login screen')),
      ),
    ],
  );

  return ProviderScope(
    overrides: [
      hasAnyItemProvider.overrideWith((ref) => hasTodosStream),
      databaseProvider.overrideWithValue(GtdDatabase(NativeDatabase.memory())),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    onboardingSeenNotifier.value = false;
  });

  tearDown(() {
    onboardingSeenNotifier.value = false;
  });

  testWidgets('card visible when hasTodos=false and not seen', (tester) async {
    await tester.pumpWidget(_buildCard(Stream.value(false)));
    await tester.pump();

    expect(find.byKey(const Key('onboarding_card')), findsOneWidget);
  });

  testWidgets('card absent when onboardingSeenNotifier starts true', (tester) async {
    onboardingSeenNotifier.value = true;
    await tester.pumpWidget(_buildCard(Stream.value(false)));
    await tester.pump();

    expect(find.byKey(const Key('onboarding_card')), findsNothing);
  });

  testWidgets('tapping Start fresh calls markOnboardingSeen and hides card',
      (tester) async {
    await tester.pumpWidget(_buildCard(Stream.value(false)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('onboarding_start_fresh')));
    await tester.pump();

    expect(onboardingSeenNotifier.value, isTrue);
    expect(find.byKey(const Key('onboarding_card')), findsNothing);
  });

  testWidgets(
      'tapping Import from Nirvana calls markOnboardingSeen and navigates to /import',
      (tester) async {
    await tester.pumpWidget(_buildCard(Stream.value(false)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('onboarding_import')));
    await tester.pumpAndSettle();

    expect(onboardingSeenNotifier.value, isTrue);
    expect(find.text('import screen'), findsOneWidget);
  });

  testWidgets(
      'tapping Sign in calls markOnboardingSeen and navigates to /login',
      (tester) async {
    await tester.pumpWidget(_buildCard(Stream.value(false)));
    await tester.pump();

    await tester.tap(find.byKey(const Key('onboarding_sign_in')));
    await tester.pumpAndSettle();

    expect(onboardingSeenNotifier.value, isTrue);
    expect(find.text('login screen'), findsOneWidget);
  });

  testWidgets('renders one greeting pair — header with its own subtitle',
      (tester) async {
    await tester.pumpWidget(_buildCard(Stream.value(false)));
    await tester.pump();

    // Exactly one header from the pool renders...
    final shown = onboardingGreetings
        .where((greeting) => find.text(greeting.header).evaluate().isNotEmpty)
        .toList();
    expect(shown, hasLength(1),
        reason: 'expected exactly one greeting header from the pool');

    // ...and its paired subtitle renders with it — never a crossed pair.
    final greeting = shown.single;
    expect(find.text(greeting.subtitle), findsOneWidget);
    for (final other in onboardingGreetings) {
      if (other == greeting) continue;
      expect(find.text(other.subtitle), findsNothing,
          reason: 'no other subtitle should render alongside ${greeting.header}');
    }

    // The old single-line copy is gone.
    expect(find.text('Your GTD inbox, sir. Shall we stock it?'), findsNothing);
  });

  testWidgets('seeded greeting is deterministic', (tester) async {
    final expected = pickOnboardingGreeting(seed: 7);
    await tester.pumpWidget(_buildCard(Stream.value(false), greetingSeed: 7));
    await tester.pump();

    expect(find.text(expected.header), findsOneWidget);
    expect(find.text(expected.subtitle), findsOneWidget);
  });

  test('pickOnboardingGreeting always returns a valid pool pair', () {
    for (var seed = 0; seed < 50; seed++) {
      final greeting = pickOnboardingGreeting(seed: seed);
      expect(onboardingGreetings, contains(greeting));
    }
  });

  testWidgets('card disappears when hasAnyItemProvider emits true', (tester) async {
    final controller = StreamController<bool>();
    controller.add(false);

    await tester.pumpWidget(_buildCard(controller.stream));
    await tester.pump();
    expect(find.byKey(const Key('onboarding_card')), findsOneWidget);

    controller.add(true);
    await tester.pump(); // stream event delivered, ref.listen fires
    await tester.pump(); // ValueListenableBuilder rebuilds after notifier update

    expect(find.byKey(const Key('onboarding_card')), findsNothing);

    await controller.close();
  });
}
