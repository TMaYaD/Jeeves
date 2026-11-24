/// The time window editor sheet (issue #55) lays out at 320 dp.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/widgets/time_window_editor_sheet.dart';

import '../test_helpers.dart';

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    db = GtdDatabase(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  testWidgets('the editor lays out at 320dp with no overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showTimeWindowEditorSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'the editor lays out clean at 320dp');

    // The name field and the day chips fit; the Save control stays on screen.
    final save = tester.getRect(find.byKey(const Key('time_window_save')));
    expect(save.left, greaterThanOrEqualTo(0.0));
    expect(save.right, lessThanOrEqualTo(320.0));
    expect(save.width, greaterThan(0.0));

    // With a day chosen, the From/To pair is on show — and still fits.
    await tester.tap(find.byKey(const Key('time_window_day_1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('time_window_start')), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'the hours row lays out clean at 320dp');

    // The day-by-day editor also fits at this width.
    await tester.tap(find.byKey(const Key('time_window_mode_different')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'the day-by-day editor lays out clean at 320dp');
  });
}
