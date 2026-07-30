import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/router.dart' show buildAppRouterRedirect;
import 'package:jeeves/screens/auth/login_screen.dart';

// ---------------------------------------------------------------------------
// Fake notifiers
// ---------------------------------------------------------------------------

/// Signs in a device that is already enrolled: straight into the app.
class _SuccessAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> login(Map<String, dynamic> params) async {
    sessionGateNotifier.value = SessionGate.ready;
    state = const AsyncData('fake.jwt.token');
  }
}

/// Signs in a device whose store says it is not enrolled: into onboarding.
class _UnenrolledAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> login(Map<String, dynamic> params) async {
    sessionGateNotifier.value = SessionGate.needsEnrolment;
    state = const AsyncData('fake.jwt.token');
  }
}

class _ConnectionErrorAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> login(Map<String, dynamic> params) async {
    final err = DioException(
      requestOptions: RequestOptions(path: '/session'),
      type: DioExceptionType.connectionError,
    );
    state = AsyncError(err, StackTrace.empty);
    throw err;
  }
}

class _FailAuthNotifier extends AuthNotifier {
  final int statusCode;
  _FailAuthNotifier(this.statusCode);

  @override
  Future<String?> build() async => null;

  @override
  Future<void> login(Map<String, dynamic> params) async {
    final err = DioException(
      requestOptions: RequestOptions(path: '/session'),
      response: Response(
        requestOptions: RequestOptions(path: '/session'),
        statusCode: statusCode,
      ),
      type: DioExceptionType.badResponse,
    );
    state = AsyncError(err, StackTrace.empty);
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _buildScreen({
  AuthNotifier Function()? notifierFactory,
  GoRouter? router,
}) {
  final r = router ??
      GoRouter(
        initialLocation: '/login',
        routes: [
          GoRoute(
              path: '/login',
              builder: (_, _) => const LoginScreen()),
          GoRoute(
              path: '/register',
              builder: (_, _) =>
                  const Scaffold(body: Text('Register'))),
          GoRoute(
              path: '/inbox',
              builder: (_, _) =>
                  const Scaffold(body: Text('Inbox'))),
        ],
      );

  return ProviderScope(
    overrides: [
      if (notifierFactory != null)
        authTokenProvider.overrideWith(notifierFactory),
    ],
    child: MaterialApp.router(routerConfig: r),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  tearDown(() => sessionGateNotifier.value = SessionGate.checking);

  group('LoginScreen — layout', () {
    testWidgets('renders email field, password field, and Sign In button',
        (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
      ));
      await tester.pump();

      expect(find.byKey(const Key('email_field')), findsOneWidget);
      expect(find.byKey(const Key('password_field')), findsOneWidget);
      expect(find.byKey(const Key('sign_in_button')), findsOneWidget);
    });
  });

  group('LoginScreen — validation', () {
    testWidgets('shows error when email is empty on submit', (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
      ));
      await tester.pump();

      await tester.tap(find.byKey(const Key('sign_in_button')));
      await tester.pump();

      expect(find.text('Email is required.'), findsOneWidget);
    });

    testWidgets('shows error when password is empty on submit', (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
      ));
      await tester.pump();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.tap(find.byKey(const Key('sign_in_button')));
      await tester.pump();

      expect(find.text('Password is required.'), findsOneWidget);
    });
  });

  group('LoginScreen — server errors', () {
    testWidgets('shows "Invalid email or password" on 401', (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: () => _FailAuthNotifier(401),
      ));
      await tester.pump();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'wrongpw');
      await tester.tap(find.byKey(const Key('sign_in_button')));
      await tester.pump(); // trigger async
      await tester.pump(); // settle state

      expect(find.text('Invalid email or password.'), findsOneWidget);
    });
  });

  group('LoginScreen — connection errors', () {
    testWidgets('shows connection error message on network failure',
        (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _ConnectionErrorAuthNotifier.new,
      ));
      await tester.pump();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password');
      await tester.tap(find.byKey(const Key('sign_in_button')));
      await tester.pump();
      await tester.pump();

      expect(find.text('Connection failed. Check your network.'), findsOneWidget);
    });
  });

  group('LoginScreen — navigation', () {
    testWidgets('tapping register link navigates to /register', (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
      ));
      await tester.pump();

      await tester.tap(find.textContaining("Don't have an account"));
      await tester.pumpAndSettle();

      expect(find.text('Register'), findsOneWidget);
    });
  });

  group('LoginScreen — success flow', () {
    // The production redirect over the production gate, with stub routes.
    GoRouter gatedRouter({String initialLocation = '/login'}) => GoRouter(
          initialLocation: initialLocation,
          redirect: buildAppRouterRedirect(swsMode: false),
          refreshListenable: sessionGateNotifier,
          routes: [
            GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
            GoRoute(
              path: '/settings',
              builder: (_, _) => Scaffold(
                body: Builder(
                  builder: (ctx) => TextButton(
                    onPressed: () => ctx.push('/login'),
                    child: const Text('Open login'),
                  ),
                ),
              ),
            ),
            GoRoute(
                path: '/inbox',
                builder: (_, _) => const Scaffold(body: Text('Inbox'))),
            GoRoute(
                path: '/enrolment',
                builder: (_, _) => const Scaffold(body: Text('Enrolment'))),
          ],
        );

    Future<void> signIn(WidgetTester tester) async {
      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password');
      await tester.tap(find.byKey(const Key('sign_in_button')));
      await tester.pumpAndSettle();
    }

    testWidgets('an enrolled device signs in straight into the app',
        (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
        router: gatedRouter(),
      ));
      await tester.pump();

      await signIn(tester);

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('an un-enrolled device signs in into onboarding',
        (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _UnenrolledAuthNotifier.new,
        router: gatedRouter(),
      ));
      await tester.pump();

      await signIn(tester);

      expect(find.text('Enrolment'), findsOneWidget);
      expect(find.text('Inbox'), findsNothing);
    });

    testWidgets('a login pushed from Settings does not pop back to it',
        (tester) async {
      // It used to pop, which on an un-enrolled device left the user on
      // Settings with onboarding unstarted. The gate routes instead.
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _UnenrolledAuthNotifier.new,
        router: gatedRouter(initialLocation: '/settings'),
      ));
      await tester.pump();

      await tester.tap(find.text('Open login'));
      await tester.pumpAndSettle();
      await signIn(tester);

      expect(find.text('Enrolment'), findsOneWidget);
      expect(find.text('Open login'), findsNothing);
      expect(find.byKey(const Key('sign_in_button')), findsNothing);
    });
  });
}
