/// The Timeboxed gate in front of the break's skip control (issue #923).
///
/// Skipping a break starts the next Sprint, so it goes past the same gate the
/// other two ways of starting a Sprint go past. Driven over a real in-memory
/// database: the limit is derived from the Action's estimate, its TimeLogs and
/// its Sprints, so the assertions read the rows the app reads.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';

import '../helpers/active_focus_harness.dart';
import '../test_helpers.dart';

const _notificationsChannel = focusNotificationsChannel;
typedef _FakeNotificationsPlatform = FakeNotificationsPlatform;

/// The sprint settings, fixed: the settings watch is a synced read, and a
/// widget test cannot let one deliver.
class _FixedFocusSettings extends FocusSettingsNotifier {
  @override
  FocusSettings build() => const FocusSettings();
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterLocalNotificationsPlatform.instance = _FakeNotificationsPlatform();
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(_notificationsChannel, (_) async => null);
    db = GtdDatabase(NativeDatabase.memory());
  });
  tearDown(() async {
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(_notificationsChannel, null);
    await db.close();
  });

  /// A Timeboxed Action whose limit has been passed: 30 minutes estimated,
  /// 50 logged.
  Future<Todo> seedPastLimit() async {
    final now = DateTime.now().toUtc();
    await db.todoDao.insertOutcome(
      id: 'o1',
      title: 'Bounded work',
      userId: focusUserId,
      now: now,
    );
    await db.actionDao.setCurrentAction(
      'o1',
      'Draft the work',
      timeEstimate: 30,
      now: now,
    );
    await db.todoDao.updateFields('o1', timeboxed: true, now: now);
    // Work already done: the limit is behind the user.
    await db.timeLogDao.openLog(
      taskId: 'o1',
      userId: focusUserId,
      now: now.subtract(const Duration(minutes: 50)),
    );
    await db.timeLogDao.closeLog(taskId: 'o1', now: now);
    return (await db.todoDao.getTodo('o1'))!;
  }

  /// The Sprints recorded.
  Future<int> sprintCount() async {
    final rows = await db.customSelect('SELECT COUNT(*) AS c FROM sprints').get();
    return rows.first.read<int>('c');
  }

  /// The screen, in a break, with the limit already passed.
  Future<void> pumpInBreak(WidgetTester tester, Todo todo) async {
    await tester.pumpWidget(
      focusHarness(
        db,
        todo: todo,
        sprintTimer: () => FixedSprintTimerNotifier(
          const SprintTimerState(
            phase: SprintPhase.break_,
            activeTaskId: 'o1',
            sprintNumber: 1,
            totalSprints: 1,
          ),
        ),
        overrides: [
          focusSettingsProvider.overrideWith(() => _FixedFocusSettings()),
        ],
      ),
    );
    await pumpFocusFrames(tester);
  }

  /// The ring's skip control — the way out of a break.
  Finder skipControl() => find.byTooltip('Start sprint');

  testWidgets('a Sprint past the limit asks before the break is skipped', (
    tester,
  ) async {
    final todo = await seedPastLimit();
    await pumpInBreak(tester, todo);

    await tester.tap(skipControl());
    await pumpFocusFrames(tester);

    // Jeeves advises, and the Sprint has not started.
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsOneWidget);
    expect(await sprintCount(), 0);
  });

  testWidgets('"Right ho" leaves the break alone', (tester) async {
    final todo = await seedPastLimit();
    await pumpInBreak(tester, todo);

    await tester.tap(skipControl());
    await pumpFocusFrames(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_stop')));
    await pumpFocusFrames(tester);

    // The sheet closes, the break carries on, and no Sprint was recorded.
    expect(find.byKey(const Key('timeboxed_gate_stop')), findsNothing);
    expect(skipControl(), findsOneWidget);
    expect(await sprintCount(), 0);
  });

  testWidgets('confirming starts the Sprint', (tester) async {
    final todo = await seedPastLimit();
    await pumpInBreak(tester, todo);

    await tester.tap(skipControl());
    await pumpFocusFrames(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_regardless')));
    await pumpFocusFrames(tester);
    await tester.tap(find.byKey(const Key('timeboxed_gate_confirm')));
    await pumpFocusFrames(tester);

    // The Sprint ran: it is recorded.
    expect(await sprintCount(), 1);
  });
}
