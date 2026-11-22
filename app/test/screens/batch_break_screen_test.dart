@TestOn('!browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/screens/batch_break_screen.dart';

class _FixedFocusSettings extends FocusSettingsNotifier {
  @override
  FocusSettings build() => const FocusSettings(shortBreakDurationMinutes: 2);
}

/// The screen reads the wall clock through [clockProvider], so a test moves
/// both that and the fake timers.
var _now = DateTime.utc(2026, 11, 20, 12);

Future<void> _advance(WidgetTester tester, Duration by) async {
  _now = _now.add(by);
  await tester.pump(by);
}

Future<void> _open(WidgetTester tester) async {
  _now = DateTime.utc(2026, 11, 20, 12);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      focusSettingsProvider.overrideWith(_FixedFocusSettings.new),
      clockProvider.overrideWithValue(() => _now),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const BatchBreakScreen())),
          child: const Text('list'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('list'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows a Break of the Settings length', (tester) async {
    await _open(tester);
    expect(find.text('02:00'), findsOneWidget);
  });

  testWidgets('End break returns to the list', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('batch-break-end')));
    await tester.pumpAndSettle();
    expect(find.byType(BatchBreakScreen), findsNothing);
    expect(find.text('list'), findsOneWidget);
  });

  testWidgets('the countdown running out returns to the list', (tester) async {
    await _open(tester);
    await _advance(tester, const Duration(minutes: 2, seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(BatchBreakScreen), findsNothing);
  });
}
