import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/screens/auth/login_screen.dart';

// ---------------------------------------------------------------------------
// Fake notifiers
// ---------------------------------------------------------------------------

class _SuccessAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> login(String email, String password) async {
    authStateNotifier.value = true;
    state = const AsyncData('fake.jwt.token');
  }
}

class _FailAuthNotifier extends AuthNotifier {
  final int statusCode;
  _FailAuthNotifier(this.statusCode);

  @override
  Future<String?> build() async => null;

  @override
  Future<void> login(String email, String password) async {
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
  tearDown(() => authStateNotifier.value = false);

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

    testWidgets('shows toggle link to register screen', (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
      ));
      await tester.pump();

      expect(find.textContaining("Don't have an account"), findsOneWidget);
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
}
