/// The sprint count is a hint, not a target (issue #912).
///
/// The real Focus screen and the real Focus Mode over a real in-memory store:
/// a 60-minute Outcome reads "about 3 sprints" beside its estimate, an Outcome
/// with no estimate reads nothing at all, and the fourth Sprint in Focus Mode
/// reads "Sprint 4" — never "Sprint 4 of 3". The dots carry the count
/// visually and simply continue past the hint; going past it warns about
/// nothing and changes no data.
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/focus_settings.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/day_timeline_provider.dart';
import 'package:jeeves/providers/focus_settings_provider.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/outcome_row.dart';

import '../helpers/active_focus_harness.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// Fixed settings, so the real timer does not open the synced-preferences
/// watch.
class _FixedFocusSettings extends FocusSettingsNotifier {
  @override
  FocusSettings build() => const FocusSettings();
}

/// A Sprint dot: 14px, filled for a Sprint done or running, outlined-empty for
/// a Sprint still to come.
bool _isFilledDot(Container dot) {
  final decoration = dot.decoration;
  if (decoration is! BoxDecoration) return false;
  if (decoration.shape != BoxShape.circle) return false;
  if (dot.constraints?.maxWidth != 14) return false;
  final color = decoration.color;
  return color != null && color != Colors.transparent;
}

bool _isEmptyDot(Container dot) {
  final decoration = dot.decoration;
  if (decoration is! BoxDecoration) return false;
  if (decoration.shape != BoxShape.circle) return false;
  if (dot.constraints?.maxWidth != 14) return false;
  final color = decoration.color;
  return color == null || color == Colors.transparent;
}

int _countDots(WidgetTester tester, bool Function(Container) matches) =>
    tester.widgetList<Container>(find.byType(Container)).where(matches).length;

/// The Plan row carrying [title].
Finder _rowWith(String title) => find.ancestor(
      of: find.descendant(
        of: find.byType(OutcomeRow),
        matching: find.text(title),
      ),
      matching: find.byType(OutcomeRow),
    );

/// Any text that reads a Sprint number against a total — "Sprint 4 of 3".
Finder _sprintOfText() => find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          RegExp(r'Sprint \d+ of').hasMatch(widget.data ?? ''),
    );

Future<Todo> _insertOutcome(
  GtdDatabase db, {
  required String id,
  required String title,
  int? timeEstimateMinutes,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        intent: const Value('next'),
        userId: const Value(_userId),
        timeEstimate: Value(timeEstimateMinutes),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(
    db,
    outcomeId: id,
    text: 'work on $title',
    userId: _userId,
  );
  return (await db.todoDao.getTodo(id))!;
}

/// Opens a TimeLog on [taskId] and runs a single Sprint on it, so the timer
/// reads as being on its first Sprint.
Future<void> _runFirstSprint(GtdDatabase db, String taskId) async {
  final now = DateTime.now();
  await db.timeLogDao.openLog(
    taskId: taskId,
    userId: _userId,
    now: now.subtract(const Duration(minutes: 3)),
  );
  await db.sprintDao.startSprint(
    taskId: taskId,
    userId: _userId,
    plannedDurationMinutes: 20,
    now: now.subtract(const Duration(minutes: 2)),
  );
}

/// The real Now screen over [db] — the Focus list, with no provider stubbed
/// except the database itself.
Widget _focusScreen(GtdDatabase db) {
  final router = GoRouter(
    initialLocation: '/focus',
    routes: [
      GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
      GoRoute(
        path: '/focus-session-planning',
        builder: (_, _) => const Scaffold(body: Text('planning')),
      ),
      GoRoute(
        path: '/focus/active',
        builder: (_, _) => const Scaffold(body: Text('active')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      nowTimelineExtrasProvider.overrideWithValue(const NowTimelineExtras()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
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
    db = GtdDatabase(NativeDatabase.memory());
  });

  tearDown(() async {
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(focusNotificationsChannel, null);
    await db.close();
  });

  group('the Focus row carries the count as a hint', () {
    testWidgets(
        'a 60-minute estimate reads "about 3 sprints"; an Outcome with no '
        'estimate reads nothing', (tester) async {
      await _insertOutcome(db,
          id: 'estimated',
          title: 'Write the proposal',
          timeEstimateMinutes: 60);
      await _insertOutcome(db, id: 'unestimated', title: 'Book the venue');
      await db.focusSessionDao
          .openSession(userId: _userId, taskIds: ['estimated', 'unestimated']);

      await tester.pumpWidget(_focusScreen(db));
      await settleWithRealAsync(tester);

      // The estimate and its hint sit side by side on the row.
      expect(
        find.descendant(
          of: _rowWith('Write the proposal'),
          matching: find.textContaining('about 3 sprints'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _rowWith('Write the proposal'),
          matching: find.text('1h'),
        ),
        findsOneWidget,
        reason: 'the hint sits beside the estimate it is derived from',
      );

      // No estimate, no hint.
      expect(
        find.descendant(
          of: _rowWith('Book the venue'),
          matching: find.textContaining('sprint'),
        ),
        findsNothing,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });

  group('Focus Mode names the Sprint it is on, and nothing else', () {
    testWidgets(
        'the fourth Sprint on a 60-minute Outcome reads "Sprint 4", with no '
        '"of", no empty dot and no warning', (tester) async {
      final todo = await tester.runAsync(() => _insertOutcome(db,
          id: 'o1', title: 'Write the proposal', timeEstimateMinutes: 60));

      // Three Sprints done and a fourth running, all on the Outcome's Action.
      await tester.runAsync(() async {
        final now = DateTime.now();
        await db.timeLogDao.openLog(
            taskId: 'o1',
            userId: _userId,
            now: now.subtract(const Duration(minutes: 40)));
        var startedAt = now.subtract(const Duration(minutes: 30));
        for (var i = 0; i < 3; i++) {
          await db.sprintDao.startSprint(
            taskId: 'o1',
            userId: _userId,
            plannedDurationMinutes: 20,
            now: startedAt,
          );
          await db.sprintDao.endRunningSprint(
            userId: _userId,
            now: startedAt.add(const Duration(minutes: 1)),
          );
          startedAt = startedAt.add(const Duration(minutes: 5));
        }
        await db.sprintDao.startSprint(
          taskId: 'o1',
          userId: _userId,
          plannedDurationMinutes: 20,
          now: now.subtract(const Duration(minutes: 2)),
        );
      });

      await tester.pumpWidget(focusHarness(
        db,
        todo: todo!,
        sprintTimer: SprintTimerNotifier.new,
        overrides: [focusSettingsProvider.overrideWith(_FixedFocusSettings.new)],
      ));
      await pumpFocusFrames(tester, 20);
      await tester.runAsync(() => pumpEventQueue(times: 20));
      await pumpFocusFrames(tester, 5);

      // The number of the Sprint, and never a total to match it against.
      expect(find.text('Sprint 4'), findsOneWidget);
      expect(_sprintOfText(), findsNothing);

      // The dots carry the count and simply continue past the hint: four
      // Sprints done or running, none still to come.
      expect(_countDots(tester, _isFilledDot), 4);
      expect(_countDots(tester, _isEmptyDot), 0);

      // Past the hint, nothing warns and nothing is written.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect((await db.todoDao.getTodo('o1'))?.timeEstimate, 60);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
        'the first Sprint of a 60-minute Outcome shows one filled dot and two '
        'empty ones, and no text reads "of 3"', (tester) async {
      final todo = await tester.runAsync(() => _insertOutcome(db,
          id: 'o1', title: 'Write the proposal', timeEstimateMinutes: 60));
      await tester.runAsync(() => _runFirstSprint(db, 'o1'));

      await tester.pumpWidget(focusHarness(
        db,
        todo: todo!,
        sprintTimer: SprintTimerNotifier.new,
        overrides: [focusSettingsProvider.overrideWith(_FixedFocusSettings.new)],
      ));
      await pumpFocusFrames(tester, 20);
      await tester.runAsync(() => pumpEventQueue(times: 20));
      await pumpFocusFrames(tester, 5);

      // The Sprint being worked, and no total to match it against.
      expect(find.text('Sprint 1'), findsOneWidget);
      expect(_sprintOfText(), findsNothing);

      // The dots carry the hint: one Sprint running, two still to come.
      expect(_countDots(tester, _isFilledDot), 1);
      expect(_countDots(tester, _isEmptyDot), 2);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('an Outcome with no estimate shows no empty dot',
        (tester) async {
      final todo = await tester.runAsync(
          () => _insertOutcome(db, id: 'o2', title: 'Book the venue'));
      await tester.runAsync(() => _runFirstSprint(db, 'o2'));

      await tester.pumpWidget(focusHarness(
        db,
        todo: todo!,
        sprintTimer: SprintTimerNotifier.new,
        overrides: [focusSettingsProvider.overrideWith(_FixedFocusSettings.new)],
      ));
      await pumpFocusFrames(tester, 20);
      await tester.runAsync(() => pumpEventQueue(times: 20));
      await pumpFocusFrames(tester, 5);

      // No estimate, no total to fill: the one Sprint running, nothing empty.
      expect(_countDots(tester, _isFilledDot), 1);
      expect(_countDots(tester, _isEmptyDot), 0);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
