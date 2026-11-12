/// The SYSTEM TRUST section of Settings (issue #52, Story D), driven against
/// real database-backed providers: crossing the Inbox limit or the Weekly
/// Review due date flips the glyphs, and each row opens its remedy.
library;

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/providers/system_trust_provider.dart';
import 'package:jeeves/screens/settings/system_trust_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers.dart';

final _lastReviewed = DateTime.utc(2026, 3, 1, 9);
final _due = _lastReviewed.add(const Duration(days: 7));

Future<void> _addCaptures(GtdDatabase db, int count) async {
  for (var i = 0; i < count; i++) {
    await db.captureDao.insertCapture(CapturesCompanion(
      id: Value('c$i'),
      title: Value('Capture $i'),
      userId: const Value('u'),
      createdAt: Value(_lastReviewed),
    ));
  }
}

void main() {
  setUpAll(() {
    configureSqliteForTests();
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late GtdDatabase db;
  late DateTime now;
  late ProviderContainer container;
  late GoRouter router;

  // ListTile merges its trailing glyph's label into the row's semantics, so
  // match the glyph's own Semantics node rather than the merged label.
  Finder _glyphLabelled(String label) => find.byWidgetPredicate(
      (widget) => widget is Semantics && widget.properties.label == label);

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
      nudgeBoundaryTickProvider
          .overrideWith((ref) => now.millisecondsSinceEpoch),
    ]);
    addTearDown(container.dispose);
    await container.read(syncedPreferencesProvider.future);
    await container
        .read(syncedPreferencesProvider.notifier)
        .set('periodic_review_last_completed_at',
            _lastReviewed.toIso8601String());
    router = GoRouter(initialLocation: '/settings', routes: [
      GoRoute(
        path: '/settings',
        builder: (_, _) => const Scaffold(body: SystemTrustSection()),
      ),
      GoRoute(path: '/inbox', builder: (_, _) => const Text('inbox page')),
      GoRoute(
          path: '/periodic-review',
          builder: (_, _) => const Text('review page')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() {
    db = GtdDatabase(NativeDatabase.memory());
    now = _lastReviewed.add(const Duration(days: 3));
  });
  tearDown(() => db.close());

  testWidgets('all good: tick in the header and both rows, days since review',
      (tester) async {
    await pump(tester);

    expect(find.text('SYSTEM TRUST'), findsOneWidget);
    expect(_glyphLabelled('All good'), findsNWidgets(3));
    expect(_glyphLabelled('Needs attention'), findsNothing);
    expect(find.text('3 days ago'), findsOneWidget);
  });

  testWidgets('crossing 50 Captures turns glyphs to rings; clarifying one '
      'turns them back', (tester) async {
    await _addCaptures(db, 51);
    await pump(tester);

    expect(_glyphLabelled('Needs attention'), findsNWidgets(2));
    expect(_glyphLabelled('All good'), findsOneWidget);

    await db.customStatement(
        "UPDATE captures SET clarified_at = '2026-03-02T00:00:00.000Z' "
        "WHERE id = 'c0'");
    db.notifyCapturesViewWrite();
    await tester.pumpAndSettle();

    expect(_glyphLabelled('Needs attention'), findsNothing);
    expect(_glyphLabelled('All good'), findsNWidgets(3));
    expect(container.read(unprocessedCaptureCountProvider), 50);
  });

  testWidgets('the review due date passing turns the review row to a ring',
      (tester) async {
    await pump(tester);
    expect(_glyphLabelled('Needs attention'), findsNothing);

    now = _due;
    container.invalidate(nudgeBoundaryTickProvider);
    await tester.pumpAndSettle();

    expect(_glyphLabelled('Needs attention'), findsNWidgets(2));
    expect(find.text('7 days ago'), findsOneWidget);
  });

  testWidgets('never reviewed says "not done yet"', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pump(tester);
    await container
        .read(syncedPreferencesProvider.notifier)
        .set('periodic_review_last_completed_at', '');
    await tester.pumpAndSettle();
    expect(find.text('not done yet'), findsOneWidget);
  });

  testWidgets('each row routes to its remedy', (tester) async {
    await pump(tester);

    await tester.tap(find.byKey(SystemTrustSection.weeklyReviewRowKey));
    await tester.pumpAndSettle();
    expect(find.text('review page'), findsOneWidget);

    router.go('/settings');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SystemTrustSection.inboxRowKey));
    await tester.pumpAndSettle();
    expect(find.text('inbox page'), findsOneWidget);
  });
}
