import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/auth/session_gate.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/router.dart' show buildAppRouterRedirect;
import 'package:jeeves/screens/auth/register_screen.dart';

// ---------------------------------------------------------------------------
// Fake notifiers
// ---------------------------------------------------------------------------

class _SuccessAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> register(String email, String password) async {
    // What the real notifier does for a brand-new account: it is signed in and
    // by definition not enrolled.
    sessionGateNotifier.value = SessionGate.signedInNotEnrolled;
    state = const AsyncData('fake.jwt.token');
  }
}

class _NetworkErrorAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> register(String email, String password) async {
    final err = DioException(
      requestOptions: RequestOptions(path: '/user'),
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
  Future<void> register(String email, String password) async {
    final err = DioException(
      requestOptions: RequestOptions(path: '/user'),
      response: Response(
        requestOptions: RequestOptions(path: '/user'),
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
        initialLocation: '/register',
        routes: [
          GoRoute(
              path: '/register',
              builder: (_, _) => const RegisterScreen()),
          GoRoute(
              path: '/login',
              builder: (_, _) => const Scaffold(body: Text('Login'))),
          GoRoute(
              path: '/inbox',
              builder: (_, _) => const Scaffold(body: Text('Inbox'))),
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

  group('RegisterScreen — layout', () {
    testWidgets('renders email field, password field, and Create Account button',
        (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
      ));
      await tester.pump();

      expect(find.byKey(const Key('email_field')), findsOneWidget);
      expect(find.byKey(const Key('password_field')), findsOneWidget);
      expect(find.byKey(const Key('create_account_button')), findsOneWidget);
    });
  });

  group('RegisterScreen — validation', () {
    testWidgets('shows error when email is empty on submit', (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
      ));
      await tester.pump();

      await tester.tap(find.byKey(const Key('create_account_button')));
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
      await tester.tap(find.byKey(const Key('create_account_button')));
      await tester.pump();

      expect(find.text('Password is required.'), findsOneWidget);
    });
  });

  group('RegisterScreen — server errors', () {
    testWidgets('shows duplicate-email message on 409', (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: () => _FailAuthNotifier(409),
      ));
      await tester.pump();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password1');
      await tester.tap(find.byKey(const Key('create_account_button')));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('An account with this email already exists.'),
        findsOneWidget,
      );
    });
  });

  group('RegisterScreen — connection errors', () {
    testWidgets('shows connection error message on network failure',
        (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _NetworkErrorAuthNotifier.new,
      ));
      await tester.pump();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password1');
      await tester.tap(find.byKey(const Key('create_account_button')));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Connection failed. Check your network.'),
        findsOneWidget,
      );
    });
  });

  group('RegisterScreen — success flow', () {
    // The production redirect over the production gate, with stub routes: what
    // is under test is that signing up needs no navigation decision of its own.
    // The gate is passed rather than left to the redirect's fallback, so what
    // the redirect reads is visible here — it is the same global the fake
    // AuthNotifiers above write and `tearDown` resets.
    GoRouter gatedRouter({String initialLocation = '/register'}) => GoRouter(
          initialLocation: initialLocation,
          redirect:
              buildAppRouterRedirect(swsMode: false, gate: sessionGateNotifier),
          refreshListenable: sessionGateNotifier,
          routes: [
            GoRoute(path: '/register', builder: (_, _) => const RegisterScreen()),
            GoRoute(
              path: '/settings',
              builder: (_, _) => Scaffold(
                body: Builder(
                  builder: (ctx) => TextButton(
                    onPressed: () => ctx.push('/register'),
                    child: const Text('Open register'),
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

    testWidgets('a fresh account is taken straight into the app',
        (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
        router: gatedRouter(),
      ));
      await tester.pump();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password1');
      await tester.tap(find.byKey(const Key('create_account_button')));
      await tester.pumpAndSettle();

      // A brand-new account is by definition un-enrolled, and #673 says that is
      // a place to work from rather than a ceremony to be marched into. The
      // account exists, the app opens, and enrolling is offered in Settings.
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Enrolment'), findsNothing);
      expect(find.byKey(const Key('create_account_button')), findsNothing);
    });

    testWidgets('a register pushed from Settings does not pop back to it',
        (tester) async {
      // It used to: the screen popped when it could, which on a signed-up but
      // un-enrolled device left the user on Settings underneath a finished
      // sign-up. `go('/inbox')` replaces the stack instead.
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
        router: gatedRouter(initialLocation: '/settings'),
      ));
      await tester.pump();

      await tester.tap(find.text('Open register'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password1');
      await tester.tap(find.byKey(const Key('create_account_button')));
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Enrolment'), findsNothing);
      expect(find.text('Open register'), findsNothing);
    });
  });

  group('RegisterScreen — navigation', () {
    testWidgets('tapping login link navigates to /login', (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
      ));
      await tester.pump();

      await tester.tap(find.textContaining('Already have an account'));
      await tester.pumpAndSettle();

      expect(find.text('Login'), findsOneWidget);
    });
  });
}
