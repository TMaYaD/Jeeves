/// Focus Mode shows a Timeboxed limit that has been passed (issue #923).
///
/// Two things are pinned here: the strip that says how far past the limit the
/// work is, and the dots — the Sprints started past the limit are red, the
/// others are unchanged.
///
/// The limit status is stubbed, as the screen's other live subject is: it is a
/// Drift watch, and a widget test cannot let one deliver. The derivation the
/// status rests on is pinned in `providers/timeboxed_limit_provider_test.dart`.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/timeboxed.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/widgets/timeboxed_limit_strip.dart';

import '../helpers/active_focus_harness.dart';
import '../test_helpers.dart';

const _notificationsChannel = focusNotificationsChannel;
typedef _FakeNotificationsPlatform = FakeNotificationsPlatform;

/// A sprint timer with a fixed state, so the dots are as many as the test
/// says they are.
class _FixedSprintTimerNotifier extends SprintTimerNotifier {
  _FixedSprintTimerNotifier(this.state);

  @override
  final SprintTimerState state;

  @override
  SprintTimerState build() => state;

  @override
  Future<void> startSprint(Todo task) async {}

  @override
  Future<void> stopSprint() async {}
}

/// The colour a dot is painted.
Color _dotColour(WidgetTester tester, int index) {
  final container = tester.widget<Container>(
    find.byKey(ValueKey('sprint_dot_$index')),
  );
  return (container.decoration! as BoxDecoration).color!;
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

  /// A limit status with [sprints] recorded Sprints, of which the ones from
  /// [firstPast] on started past the limit.
  TimeboxedLimitStatus status({
    required DateTime limitPassedAt,
    required List<DateTime> sprintStarts,
    required int firstPast,
  }) {
    return TimeboxedLimitStatus(
      limitMinutes: 30,
      limitPassedAt: limitPassedAt,
      sprintsBeforeLimit: firstPast,
      sprintsPastLimit: sprintStarts.length - firstPast,
      sprintStarts: sprintStarts,
    );
  }

  testWidgets('a passed limit says how far past it is', (tester) async {
    final todo = await insertFocusTodo(db, id: 'o1');
    final now = DateTime.now().toUtc();
    final passed = now.subtract(const Duration(minutes: 20));

    await tester.pumpWidget(
      focusHarness(
        db,
        todo: todo,
        timeboxedLimit: status(
          limitPassedAt: passed,
          sprintStarts: [
            passed.subtract(const Duration(minutes: 10)),
            passed.add(const Duration(minutes: 5)),
          ],
          firstPast: 1,
        ),
      ),
    );
    await pumpFocusFrames(tester);

    expect(find.byType(TimeboxedLimitStrip), findsOneWidget);
    expect(find.textContaining('20m past'), findsOneWidget);
    expect(find.text('Sprint 1 past the limit'), findsOneWidget);
  });

  testWidgets('a Sprint that started before the limit says nothing more', (
    tester,
  ) async {
    final todo = await insertFocusTodo(db, id: 'o5');
    final now = DateTime.now().toUtc();
    final passed = now.subtract(const Duration(minutes: 20));

    await tester.pumpWidget(
      focusHarness(
        db,
        todo: todo,
        timeboxedLimit: status(
          limitPassedAt: passed,
          // The running Sprint started before the limit passed.
          sprintStarts: [passed.subtract(const Duration(minutes: 10))],
          firstPast: 1,
        ),
      ),
    );
    await pumpFocusFrames(tester);

    expect(find.byType(TimeboxedLimitStrip), findsOneWidget);
    expect(find.textContaining('20m past'), findsOneWidget);
    // The quieter line is there only when the running Sprint is one of the
    // ones started past the limit.
    expect(find.textContaining('past the limit'), findsNothing);
  });

  testWidgets('a limit that has not passed says nothing', (tester) async {
    final todo = await insertFocusTodo(db, id: 'o2');
    final now = DateTime.now().toUtc();

    await tester.pumpWidget(
      focusHarness(
        db,
        todo: todo,
        timeboxedLimit: status(
          limitPassedAt: now.add(const Duration(minutes: 10)),
          sprintStarts: [now],
          firstPast: 0,
        ),
      ),
    );
    await pumpFocusFrames(tester);

    expect(find.byType(TimeboxedLimitStrip), findsNothing);
  });

  testWidgets('the dots for Sprints past the limit are red', (tester) async {
    final todo = await insertFocusTodo(db, id: 'o3');
    final now = DateTime.now().toUtc();
    final passed = now.subtract(const Duration(minutes: 20));

    await tester.pumpWidget(
      focusHarness(
        db,
        todo: todo,
        sprintTimer: () => _FixedSprintTimerNotifier(
          const SprintTimerState(
            phase: SprintPhase.focus,
            activeTaskId: 'o3',
            sprintNumber: 3,
            totalSprints: 3,
          ),
        ),
        timeboxedLimit: status(
          limitPassedAt: passed,
          sprintStarts: [
            passed.subtract(const Duration(minutes: 10)),
            passed.add(const Duration(minutes: 5)),
            passed.add(const Duration(minutes: 10)),
          ],
          firstPast: 1,
        ),
      ),
    );
    await pumpFocusFrames(tester);

    // The first Sprint started before the limit: unchanged.
    expect(_dotColour(tester, 0), const Color(0xFF2563EB));
    // The second and third started past it.
    expect(_dotColour(tester, 1), const Color(0xFFDC2626));
    expect(_dotColour(tester, 2), const Color(0xFFDC2626));
  });

  testWidgets('dots stay blue when no Sprint started past the limit', (
    tester,
  ) async {
    final todo = await insertFocusTodo(db, id: 'o4');
    final now = DateTime.now().toUtc();

    await tester.pumpWidget(
      focusHarness(
        db,
        todo: todo,
        sprintTimer: () => _FixedSprintTimerNotifier(
          const SprintTimerState(
            phase: SprintPhase.focus,
            activeTaskId: 'o4',
            sprintNumber: 2,
            totalSprints: 2,
          ),
        ),
        timeboxedLimit: status(
          limitPassedAt: now.add(const Duration(minutes: 10)),
          sprintStarts: [now, now],
          firstPast: 0,
        ),
      ),
    );
    await pumpFocusFrames(tester);

    expect(_dotColour(tester, 0), const Color(0xFF2563EB));
    expect(_dotColour(tester, 1), const Color(0xFF2563EB));
  });
}
