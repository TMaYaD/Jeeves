/// Widget tests for the global capture sheet (#458).
///
/// The write path is the real one — a real in-memory Drift database, no mocks —
/// so a Capture created through the sheet is verified to be exactly what the
/// Inbox `QuickAddBar` produces.
///
/// Reads go through `tester.runAsync` with a one-shot `get()`, never a drift
/// `watch()` stream: awaiting a live drift stream inside `testWidgets` never
/// completes, because the test binding owns the clock (docs/TESTING.md).
library;

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/widgets/app_title_bar/app_title_bar.dart';
import 'package:jeeves/widgets/capture/capture_action.dart';
import 'package:jeeves/widgets/capture/capture_sheet.dart';
import '../../test_helpers.dart';

Widget _wrapSheet(GtdDatabase db) => ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: const MaterialApp(
        home: Scaffold(body: CaptureSheet()),
      ),
    );

/// A host scaffold whose pinned title-bar action opens the real capture sheet —
/// exercises the production `captureAction` → `showCaptureSheet` path, the way
/// every screen mounts it, including dismissal.
Widget _wrapHost(GtdDatabase db) => ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppTitleBar(
              title: 'Host',
              leading: AppTitleBarLeading.none,
              pinnedAction: captureAction(context),
            ),
            body: const Center(child: Text('host')),
          ),
        ),
      ),
    );

/// Every Inbox Capture (`clarified_at IS NULL`), oldest first.
Future<List<Capture>> _inbox(WidgetTester tester, GtdDatabase db) async {
  final rows = await tester.runAsync(
    () => (db.select(db.captures)
          ..where((c) => c.clarifiedAt.isNull())
          ..orderBy([(c) => OrderingTerm.asc(c.createdAt)]))
        .get(),
  );
  return rows!;
}

/// Types [title] into the sheet and submits it, letting the write settle.
Future<void> _capture(WidgetTester tester, String title) async {
  await tester.enterText(find.byKey(const Key('capture_sheet_field')), title);
  await tester.pump();
  await tester.tap(find.byKey(const Key('capture_sheet_submit')));
  // Two pumps: one to dispatch the tap, one to rebuild after the write's
  // future resolves.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(configureSqliteForTests);

  testWidgets('submitting a title writes a raw Capture to the Inbox',
      (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_wrapSheet(db));
    await tester.pump();

    await _capture(tester, 'Buy milk');

    final rows = await _inbox(tester, db);
    expect(rows, hasLength(1));
    expect(rows.single.title, 'Buy milk');
    // ADR-0006: a raw Capture — unclarified, manual source. Identical to a
    // Capture created via the Inbox QuickAddBar.
    expect(rows.single.clarifiedAt, isNull);
    expect(rows.single.captureSource, 'manual');
  });

  testWidgets('sheet stays open on submit: field clears, confirmation shows, '
      'and no snackbar is used', (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_wrapSheet(db));
    await tester.pump();

    // No confirmation before the first capture.
    expect(find.byKey(const Key('capture_sheet_confirmation')), findsNothing);

    await _capture(tester, 'First thought');

    // The sheet is still mounted — the stay-open flow — the field cleared, and
    // the inline confirmation IS the affordance that the Capture landed.
    expect(find.byType(CaptureSheet), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('capture_sheet_field')))
          .controller
          ?.text,
      isEmpty,
    );
    expect(find.byKey(const Key('capture_sheet_confirmation')), findsOneWidget);
    expect(find.text('Captured to Inbox'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('focus returns to the input after submit so capture can chain',
      (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_wrapSheet(db));
    await tester.pump();

    await _capture(tester, 'First thought');

    final field = tester
        .widget<TextField>(find.byKey(const Key('capture_sheet_field')));
    expect(field.focusNode?.hasFocus, isTrue);
  });

  testWidgets('rapid multi-capture: three submits create three Captures',
      (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_wrapSheet(db));
    await tester.pump();

    for (final t in ['One', 'Two', 'Three']) {
      await _capture(tester, t);
    }

    final rows = await _inbox(tester, db);
    expect(rows.map((c) => c.title).toList(), ['One', 'Two', 'Three']);
    // The running count is surfaced inline on repeats.
    expect(find.text('Captured to Inbox · 3 captured'), findsOneWidget);
  });

  testWidgets('blank input writes nothing', (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_wrapSheet(db));
    await tester.pump();

    await _capture(tester, '   ');

    expect(await _inbox(tester, db), isEmpty);
    expect(find.byKey(const Key('capture_sheet_confirmation')), findsNothing);
  });

  testWidgets('the pinned capture action opens the sheet', (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_wrapHost(db));
    await tester.pump();

    expect(find.byType(CaptureSheet), findsNothing);

    await tester.tap(find.byKey(const Key('capture_action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(CaptureSheet), findsOneWidget);
  });

  testWidgets('opening then dismissing the sheet creates no Capture',
      (tester) async {
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_wrapHost(db));
    await tester.pump();

    await tester.tap(find.byKey(const Key('capture_action')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CaptureSheet), findsOneWidget);

    // Dismiss by tapping the modal scrim above the sheet.
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(CaptureSheet), findsNothing);
    expect(await _inbox(tester, db), isEmpty);
  });
}
