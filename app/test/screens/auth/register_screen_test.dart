import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/screens/auth/register_screen.dart';

// ---------------------------------------------------------------------------
// Fake notifiers
// ---------------------------------------------------------------------------

class _SuccessAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> register(String email, String password) async {
    authStateNotifier.value = true;
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
  tearDown(() => authStateNotifier.value = false);

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

    testWidgets('shows toggle link to login screen', (tester) async {
      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
      ));
      await tester.pump();

      expect(find.textContaining('Already have an account'), findsOneWidget);
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
    testWidgets('successful registration triggers router redirect to /inbox',
        (tester) async {
      final router = GoRouter(
        initialLocation: '/register',
        refreshListenable: authStateNotifier,
        redirect: (_, state) {
          if (authStateNotifier.value && state.uri.path == '/register') {
            return '/inbox';
          }
          return null;
        },
        routes: [
          GoRoute(
              path: '/register',
              builder: (_, _) => const RegisterScreen()),
          GoRoute(
              path: '/inbox',
              builder: (_, _) => const Scaffold(body: Text('Inbox'))),
        ],
      );

      await tester.pumpWidget(_buildScreen(
        notifierFactory: _SuccessAuthNotifier.new,
        router: router,
      ));
      await tester.pump();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password1');
      await tester.tap(find.byKey(const Key('create_account_button')));
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsOneWidget);
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
