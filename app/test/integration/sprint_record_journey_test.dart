/// A Sprint is recorded, and Focus Mode reads it back (issue #910).
///
/// The real [SprintTimerNotifier] over a real in-memory database, with **empty**
/// SharedPreferences: every assertion about the timer's state is therefore a
/// statement about what the record alone carries.
@TestOn('!browser')
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlatform;
import 'package:flutter/material.dart' show SizedBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/screens/active_focus_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../helpers/active_focus_harness.dart';
import '../test_helpers.dart';

/// Fixed settings, so the real timer does not open the synced-preferences watch.
class _FixedFocusSettings extends FocusSettingsNotifier {
  @override
  FocusSettings build() => const FocusSettings();
}

void main() {
  setUpAll(() {
    configureSqliteForTests();
    // The Sprint-end notifications are scheduled in the device's time zone.
    tz_data.initializeTimeZones();
  });

  late GtdDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterLocalNotificationsPlatform.instance = FakeNotificationsPlatform();
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(focusNotificationsChannel, (_) async => null);
    db = openFocusInMemory();
  });
  tearDown(() async {
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(focusNotificationsChannel, null);
    await db.close();
  });

  testWidgets(
      'start Focus, take a break, start the next Sprint, restart: the record '
      'carries all of it', (tester) async {
    final todo = await tester.runAsync(() async {
      final inserted = await insertFocusTodo(db, id: 'o1');
      await db.timeLogDao.openLog(
          taskId: 'o1', userId: focusUserId, now: DateTime.now());
      return inserted;
    });

    await tester.pumpWidget(
        focusHarness(
      db,
      todo: todo!,
      sprintTimer: SprintTimerNotifier.new,
      overrides: [focusSettingsProvider.overrideWith(_FixedFocusSettings.new)],
    ));
    await pumpFocusFrames(tester, 20);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ActiveFocusScreen)));
    Future<List<Sprint>> sprintRows() =>
        db.select(db.sprints).get();

    // Starting Focus records one open Sprint.
    var rows = (await tester.runAsync(sprintRows))!;
    expect(rows, hasLength(1));
    expect(rows.single.endedAt, isNull);
    expect(rows.single.plannedDurationMinutes, 20);
    expect(container.read(sprintTimerProvider).phase, SprintPhase.focus);
    expect(container.read(sprintTimerProvider).sprintNumber, 1);

    // Start break: the Sprint ends at the real time, the TimeLog stays open.
    final notifier = container.read(sprintTimerProvider.notifier);
    await tester.runAsync(notifier.startBreak);
    rows = (await tester.runAsync(sprintRows))!;
    expect(rows.single.endedAt, isNotNull);
    expect(container.read(sprintTimerProvider).phase, SprintPhase.break_);
    final openLogs = (await tester.runAsync(() => (db.select(db.timeLogs)
          ..where((t) => t.endedAt.isNull()))
        .get()))!;
    expect(openLogs, hasLength(1), reason: 'breaks still count: one TimeLog');

    // Start sprint (skip the break): a second row.
    await tester.runAsync(notifier.skipBreak);
    rows = (await tester.runAsync(sprintRows))!;
    expect(rows, hasLength(2));
    expect(rows.where((r) => r.endedAt == null), hasLength(1));
    expect(container.read(sprintTimerProvider).sprintNumber, 2);

    // A third Sprint, so the number and the dots have something to count.
    await tester.runAsync(notifier.startBreak);
    await tester.runAsync(notifier.skipBreak);
    expect(container.read(sprintTimerProvider).sprintNumber, 3,
        reason: 'two closed Sprints and the running one');

    // Restart: a fresh container over the same database and empty prefs.
    final restarted = ProviderContainer(
        overrides: [
      databaseProvider.overrideWithValue(db),
      focusSettingsProvider.overrideWith(_FixedFocusSettings.new),
    ]);
    restarted.read(sprintTimerProvider);
    await tester.runAsync(() => pumpEventQueue(times: 20));
    final restored = restarted.read(sprintTimerProvider);
    expect(restored.phase, SprintPhase.focus);
    expect(restored.sprintNumber, 3);
    expect(restored.activeTaskId, 'o1');
    expect(restored.remaining, greaterThan(Duration.zero));
    expect(restored.remaining, lessThanOrEqualTo(const Duration(minutes: 20)));

    // Dispose both so no ticker outlives the test.
    restarted.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'a restart during a Break adopts the Break: no Sprint is recorded',
      (tester) async {
    final todo = await tester.runAsync(() async {
      final inserted = await insertFocusTodo(db, id: 'o1');
      await db.timeLogDao.openLog(
          taskId: 'o1', userId: focusUserId, now: DateTime.now());
      final startedAt = DateTime.now().subtract(const Duration(minutes: 5));
      await db.sprintDao.startSprint(
          taskId: 'o1',
          userId: focusUserId,
          plannedDurationMinutes: 20,
          now: startedAt);
      await db.sprintDao.endRunningSprint(userId: focusUserId);
      return inserted;
    });
    final rowsBefore =
        (await tester.runAsync(() => db.select(db.sprints).get()))!;
    expect(rowsBefore, hasLength(1));

    // The screen mounts over a notifier that has not reloaded yet: this is the
    // restart (and the second-device) path.
    await tester.pumpWidget(focusHarness(
      db,
      todo: todo!,
      sprintTimer: SprintTimerNotifier.new,
      overrides: [focusSettingsProvider.overrideWith(_FixedFocusSettings.new)],
    ));
    await pumpFocusFrames(tester, 20);
    await tester.runAsync(() => pumpEventQueue(times: 20));
    await pumpFocusFrames(tester, 5);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ActiveFocusScreen)));
    expect(container.read(sprintTimerProvider).phase, SprintPhase.break_);
    final rowsAfter =
        (await tester.runAsync(() => db.select(db.sprints).get()))!;
    expect(rowsAfter, hasLength(1),
        reason: 'opening Focus during a Break must not record a Sprint');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
