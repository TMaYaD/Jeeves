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

Widget _buildCard(Stream<bool> hasTodosStream) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: SingleChildScrollView(child: OnboardingCard())),
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
      hasTodosProvider.overrideWith((ref) => hasTodosStream),
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

  testWidgets('card disappears when hasTodosProvider emits true', (tester) async {
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
