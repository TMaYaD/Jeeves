import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/screens/auth/login_screen.dart';
import 'package:jeeves/services/migration_service.dart';

// ---------------------------------------------------------------------------
// Fake notifiers
// ---------------------------------------------------------------------------

class _SuccessAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> login(String email, String password,
      {Future<ConflictResolution> Function()? onConflict}) async {
    authStateNotifier.value = true;
    state = const AsyncData('fake.jwt.token');
  }
}

class _ConflictAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> login(String email, String password,
      {Future<ConflictResolution> Function()? onConflict}) async {
    // Trigger the conflict dialog, then succeed.
    if (onConflict != null) {
      await onConflict();
    }
    authStateNotifier.value = true;
    state = const AsyncData('fake.jwt.token');
  }
}

class _ConnectionErrorAuthNotifier extends AuthNotifier {
  @override
  Future<String?> build() async => null;

  @override
  Future<void> login(String email, String password,
      {Future<ConflictResolution> Function()? onConflict}) async {
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
  Future<void> login(String email, String password,
      {Future<ConflictResolution> Function()? onConflict}) async {
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
    testWidgets('successful login triggers router redirect to /inbox',
        (tester) async {
      final router = GoRouter(
        initialLocation: '/login',
        refreshListenable: authStateNotifier,
        redirect: (_, state) {
          if (authStateNotifier.value && state.uri.path == '/login') {
            return '/inbox';
          }
          return null;
        },
        routes: [
          GoRoute(
              path: '/login',
              builder: (_, _) => const LoginScreen()),
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
          find.byKey(const Key('password_field')), 'password');
      await tester.tap(find.byKey(const Key('sign_in_button')));
      await tester.pumpAndSettle();

      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('when pushed from another route, pops back on success',
        (tester) async {
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
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
          GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
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

      await tester.tap(find.text('Open login'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password');
      await tester.tap(find.byKey(const Key('sign_in_button')));
      await tester.pumpAndSettle();

      // Should have popped back to /settings, NOT redirected to /inbox.
      expect(find.text('Open login'), findsOneWidget);
      expect(find.byKey(const Key('sign_in_button')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'pushed login + conflict dialog: pops back to caller after resolving',
        (tester) async {
      // Matches production: authStateNotifier is NOT in refreshListenable.
      // Including it would rebuild the route stack when login flips it,
      // dropping the imperatively-pushed /login entry and breaking pop.
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
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
          GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
        ],
      );

      await tester.pumpWidget(_buildScreen(
        notifierFactory: _ConflictAuthNotifier.new,
        router: router,
      ));
      await tester.pump();

      await tester.tap(find.text('Open login'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.byKey(const Key('email_field')), 'a@b.com');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password');
      await tester.tap(find.byKey(const Key('sign_in_button')));
      await tester.pump(); // start async
      await tester.pump(); // show dialog

      // Conflict dialog is up.
      expect(find.text('Data conflict'), findsOneWidget);

      await tester.tap(find.text('Merge both'));
      await tester.pumpAndSettle();

      // Dialog dismissed AND we popped back to /settings.
      expect(find.text('Data conflict'), findsNothing);
      expect(find.text('Open login'), findsOneWidget);
      expect(find.byKey(const Key('sign_in_button')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}
