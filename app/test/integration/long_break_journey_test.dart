/// The long Break arrives after a run of Sprints, and the TimeLog survives it
/// (issue #911).
///
/// The real [SprintTimerNotifier] over a real in-memory database, with the
/// recorded Sprints written at the instants the story describes: every
/// assertion is therefore a statement about what the record carries.
@TestOn('!browser')
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlatform;
import 'package:flutter/material.dart' show SizedBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/screens/active_focus_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../helpers/active_focus_harness.dart';
import '../test_helpers.dart';

/// The default settings, so the real timer does not open the synced-
/// preferences watch.
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

  /// Records one Sprint on [taskId], from [start] to [end] after [base].
  Future<void> recordSprint(
    GtdDatabase database, {
    required String taskId,
    required DateTime base,
    required Duration start,
    required Duration end,
  }) async {
    await database.sprintDao.startSprint(
      taskId: taskId,
      userId: focusUserId,
      plannedDurationMinutes: 20,
      now: base.add(start),
    );
    await database.sprintDao
        .endRunningSprint(userId: focusUserId, now: base.add(end));
  }

  /// The open TimeLogs, if any.
  Future<List<TimeLog>> openLogs(GtdDatabase database) =>
      (database.select(database.timeLogs)
            ..where((t) => t.endedAt.isNull()))
          .get();

  testWidgets(
      'four Sprints in a row, one of them on another Action: the Break after '
      'the fourth is the long one, and the TimeLog stays open', (tester) async {
    // The run of Sprints: 0-20, 23-43, 46-66, 69-89 after [base]. The Break
    // after the fourth ends 92 minutes after the first Sprint began, which is
    // the budget at the defaults (4 x (20 + 3)).
    final base = DateTime.now().subtract(const Duration(minutes: 95));

    final todo = await tester.runAsync(() async {
      final inserted = await insertFocusTodo(db, id: 'o1');
      await insertFocusTodo(db, id: 'o2');
      await db.timeLogDao.openLog(
          taskId: 'o1',
          userId: focusUserId,
          now: base.subtract(const Duration(minutes: 1)));
      await recordSprint(db,
          taskId: 'o1', base: base, start: Duration.zero, end: const Duration(minutes: 20));
      await recordSprint(db,
          taskId: 'o2',
          base: base,
          start: const Duration(minutes: 23),
          end: const Duration(minutes: 43));
      await recordSprint(db,
          taskId: 'o1',
          base: base,
          start: const Duration(minutes: 46),
          end: const Duration(minutes: 66));
      await recordSprint(db,
          taskId: 'o1',
          base: base,
          start: const Duration(minutes: 69),
          end: const Duration(minutes: 89));
      return inserted;
    });

    await tester.pumpWidget(focusHarness(
      db,
      todo: todo!,
      sprintTimer: SprintTimerNotifier.new,
      overrides: [focusSettingsProvider.overrideWith(_FixedFocusSettings.new)],
    ));
    await pumpFocusFrames(tester, 20);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ActiveFocusScreen)));
    final state = container.read(sprintTimerProvider);
    expect(state.phase, SprintPhase.break_);
    expect(state.isLongBreak, isTrue,
        reason: 'the Break after the fourth Sprint ends at the 92-minute '
            'budget');
    expect(state.currentBreakDurationMinutes, 15);
    expect(state.sprintsBeforeLongBreak, 4);
    expect(find.text('Long break'), findsOneWidget);

    // The long Break is a Break, not the end of the session: the TimeLog is
    // still open.
    final logs = (await tester.runAsync(() => openLogs(db)))!;
    expect(logs, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'two Sprints stopped after 5 minutes each, then a full one: the Break '
      'is the short one', (tester) async {
    // 0-5, 8-13, 16-36 after [base]: the Break after the third ends 39
    // minutes after the first Sprint began, well inside the 92-minute budget.
    final base = DateTime.now().subtract(const Duration(minutes: 37));

    final todo = await tester.runAsync(() async {
      final inserted = await insertFocusTodo(db, id: 'o1');
      await db.timeLogDao.openLog(
          taskId: 'o1',
          userId: focusUserId,
          now: base.subtract(const Duration(minutes: 1)));
      await recordSprint(db,
          taskId: 'o1', base: base, start: Duration.zero, end: const Duration(minutes: 5));
      await recordSprint(db,
          taskId: 'o1',
          base: base,
          start: const Duration(minutes: 8),
          end: const Duration(minutes: 13));
      await recordSprint(db,
          taskId: 'o1',
          base: base,
          start: const Duration(minutes: 16),
          end: const Duration(minutes: 36));
      return inserted;
    });

    await tester.pumpWidget(focusHarness(
      db,
      todo: todo!,
      sprintTimer: SprintTimerNotifier.new,
      overrides: [focusSettingsProvider.overrideWith(_FixedFocusSettings.new)],
    ));
    await pumpFocusFrames(tester, 20);

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ActiveFocusScreen)));
    final state = container.read(sprintTimerProvider);
    expect(state.phase, SprintPhase.break_);
    expect(state.isLongBreak, isFalse);
    expect(state.currentBreakDurationMinutes, 3);
    expect(find.text('Long break'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
