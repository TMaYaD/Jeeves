/// The long Break reads as the long one on the Focus screen (issue #911).
///
/// The screen at fixed timer states: the long Break names itself and carries
/// the hairline outside the ring, the short Break does neither.
@TestOn('!browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show FlutterLocalNotificationsPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/sprint_timer_provider.dart';
import 'package:jeeves/widgets/elapsed_timer_widget.dart';
import 'package:jeeves/widgets/sprint_ring.dart' show RingPainter;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;

import '../helpers/active_focus_harness.dart';
import '../test_helpers.dart';

/// The colour of the hairline outside the ring, or null when it carries none.
///
/// Read from the ring's public painter.
Color? _hairline(WidgetTester tester) {
  for (final element in find.byType(CustomPaint).evaluate()) {
    final painter = (element.widget as CustomPaint).painter;
    if (painter is! RingPainter) continue;
    return painter.hairlineColor;
  }
  fail('the sprint ring painter is not in the tree');
}

/// Every line the banner shows.
///
/// The lines are picked at random from the pool, so the test asks which of
/// them is on offer rather than which one turned up.
List<String> _bannerTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(
        of: find.byType(ElapsedTimerWidget), matching: find.byType(Text)))
    .map((text) => text.data)
    .whereType<String>()
    .toList();

/// The lines on offer during a long Break after a run of four Sprints.
final List<String> _longBreakPool = ElapsedTimerWidget.longBreakLines(
  longBreakMinutes: 15,
  sprintCount: 4,
);

SprintTimerState _longBreak() => SprintTimerState(
      phase: SprintPhase.break_,
      activeTaskId: 'o1',
      sprintNumber: 4,
      remaining: const Duration(minutes: 15),
      total: const Duration(minutes: 15),
      currentBreakDurationMinutes: 15,
      isLongBreak: true,
      longBreakSprintCount: 4,
    );

void main() {
  setUpAll(() {
    configureSqliteForTests();
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

  Future<void> mount(WidgetTester tester, SprintTimerState state) async {
    final todo = await tester.runAsync(() => insertFocusTodo(db, id: 'o1'));
    await tester.pumpWidget(focusHarness(
      db,
      todo: todo!,
      sprintTimer: () => FixedSprintTimerNotifier(state),
    ));
    await pumpFocusFrames(tester, 10);
  }

  testWidgets('the long Break names itself and carries the hairline',
      (tester) async {
    await mount(tester, _longBreak());

    expect(find.text('Long break'), findsOneWidget);
    expect(_hairline(tester), const Color(0xFF10B981));
    expect(
      _bannerTexts(tester).where(_longBreakPool.contains),
      isNotEmpty,
      reason: 'the banner speaks in the long Break\'s own lines',
    );
  });

  test('the Sprints line names the Sprints the run actually holds', () {
    final three = ElapsedTimerWidget.longBreakLines(
      longBreakMinutes: 15,
      sprintCount: 3,
    );
    expect(
      three,
      contains('A longer pause, sir. Three sprints is a respectable showing.'),
    );
    expect(
      three.where((line) => line.contains('Four sprints')),
      isEmpty,
      reason: 'the long Break came after three Sprints, so no line may say four',
    );
  });

  test('one Sprint in the run reads as one Sprint', () {
    expect(
      ElapsedTimerWidget.longBreakLines(longBreakMinutes: 15, sprintCount: 1),
      contains('A longer pause, sir. One sprint is a respectable showing.'),
    );
  });

  test('the Sprints line begins with a capital letter (Jeeves\'s standards)',
      () {
    for (final count in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12]) {
      final line = ElapsedTimerWidget.jeevesSprintsLine(count);
      expect(line, startsWith('A longer pause, sir. '));
      final number = line.substring('A longer pause, sir. '.length);
      expect(number[0], equals(number[0].toUpperCase()),
          reason: 'the count in "$line" starts lowercase');
    }
  });

  testWidgets('the banner never claims a Sprint count that did not happen',
      (tester) async {
    await mount(
      tester,
      _longBreak().copyWith(longBreakSprintCount: 3),
    );

    final spoken = _bannerTexts(tester);
    expect(spoken, isNotEmpty);
    expect(
      spoken.where((line) => line.contains('Four sprints')),
      isEmpty,
      reason: 'the run held three Sprints, so the banner may not say four',
    );
    // Whatever line the banner picked, it is one of the lines on offer for a
    // run of three Sprints.
    final pool = ElapsedTimerWidget.longBreakLines(
      longBreakMinutes: 15,
      sprintCount: 3,
    );
    expect(
      spoken.where((line) => pool.contains(line)),
      isNotEmpty,
      reason: 'the banner speaks in the long Break\'s own lines',
    );
  });

  testWidgets('a long Break run over is met with patience', (tester) async {
    await mount(
      tester,
      _longBreak().copyWith(
        phase: SprintPhase.breakOvertime,
        remaining: Duration.zero,
        overtime: const Duration(minutes: 4),
      ),
    );

    expect(find.text('Long break'), findsOneWidget);
    expect(_hairline(tester), const Color(0xFF10B981));
    expect(
      find.text('Take your time, sir. I shall keep the minutes.'),
      findsOneWidget,
    );
  });

  testWidgets('the short Break names itself not at all', (tester) async {
    await mount(
      tester,
      SprintTimerState(
        phase: SprintPhase.break_,
        activeTaskId: 'o1',
        sprintNumber: 2,
        remaining: const Duration(minutes: 3),
        total: const Duration(minutes: 3),
        currentBreakDurationMinutes: 3,
      ),
    );

    expect(find.text('Long break'), findsNothing);
    expect(_hairline(tester), isNull);
    expect(
      _bannerTexts(tester).where(_longBreakPool.contains),
      isEmpty,
      reason: 'a short Break never speaks in the long Break\'s lines',
    );
  });
}
