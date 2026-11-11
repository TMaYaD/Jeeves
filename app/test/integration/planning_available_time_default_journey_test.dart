import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/screens/planning/steps/day_checkin_time_step.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

/// Journey: the Time step of Daily Planning opens pre-filled with the
/// available time of the previous session, across process restarts (#825).
void main() {
  setUpAll(configureSqliteForTests);
  late Directory storeDirectory;
  late File storeFile;
  late GtdDatabase db;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storeDirectory = await Directory.systemTemp.createTemp('planning-time-');
    storeFile = File('${storeDirectory.path}/planning.sqlite');
    db = GtdDatabase(NativeDatabase(storeFile));
    container = createPeriodicReviewTestContainer(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    await storeDirectory.delete(recursive: true);
  });

  Future<void> restart(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      container.dispose();
      await db.close();
      db = GtdDatabase(NativeDatabase(storeFile));
      container = createPeriodicReviewTestContainer(db);
    });
  }

  /// Opens the Time step as Daily Planning does on mount.
  Future<void> openTimeStep(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: DayCheckinTimeStep())),
    ));
    await tester.runAsync(() => container
        .read(focusSessionPlanningProvider.notifier)
        .ensureAvailableTimePreload());
    await settleWithRealAsync(tester);
  }

  String fieldText(WidgetTester tester, int index) => tester
      .widget<TextField>(find.byType(TextField).at(index))
      .controller!
      .text;

  Future<void> planAndStart(
      WidgetTester tester, int hours, int minutes) async {
    await tester.enterText(find.byType(TextField).at(0), '$hours');
    await tester.enterText(find.byType(TextField).at(1), '$minutes');
    await tester.pump();
    await tester.runAsync(() async {
      await container.read(focusSessionPlanningProvider.notifier).startDay();
      final session = await db.focusSessionDao.getActiveSession();
      await db.focusSessionDao.closeSession(sessionId: session!.id);
    });
  }

  testWidgets('time step follows the previous session across restarts',
      (tester) async {
    await openTimeStep(tester);
    expect(fieldText(tester, 0), '8');
    expect(fieldText(tester, 1), '0');

    await planAndStart(tester, 5, 30);
    await restart(tester);
    await openTimeStep(tester);
    expect(fieldText(tester, 0), '5');
    expect(fieldText(tester, 1), '30');

    await planAndStart(tester, 6, 0);
    await restart(tester);
    await openTimeStep(tester);
    expect(fieldText(tester, 0), '6');
    expect(fieldText(tester, 1), '0');

    // An edit with no session started does not change the default.
    await tester.enterText(find.byType(TextField).at(0), '2');
    await tester.pump();
    await restart(tester);
    await openTimeStep(tester);
    expect(fieldText(tester, 0), '6');
  });
}
