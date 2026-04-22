import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/auth/sws/sws_login_widget.dart';

void main() {
  group('SwsLoginWidget', () {
    testWidgets('renders Connect wallet button', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: SwsLoginWidget()),
          ),
        ),
      );

      expect(find.byKey(const Key('connect_wallet_button')), findsOneWidget);
      expect(find.text('Connect wallet'), findsOneWidget);
    });

    testWidgets('button is enabled initially (not loading)', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(body: SwsLoginWidget()),
          ),
        ),
      );

      final button = tester.widget<ElevatedButton>(
        find.byKey(const Key('connect_wallet_button')),
      );
      expect(button.onPressed, isNotNull);
    });
  });
}
