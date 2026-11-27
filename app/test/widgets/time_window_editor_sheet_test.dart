/// The time window editor sheet (issue #55) lays out at 320 dp, and edits the
/// hours the way the user reads them.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_window_hours.dart';
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

  Widget harness({TimeWindow? window}) {
    return ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showTimeWindowEditorSheet(context, window: window),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => pumpEventQueue());
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<TimeWindow> windowNamed(String name, Map<int, DayHours> hours) async {
    final id = await db.timeWindowDao.createTimeWindow(
      name: name,
      hours: hours,
      userId: 'local',
    );
    expect(id, isNotNull);
    return (await db.select(db.timeWindows).getSingle());
  }

  /// Picks [hour]:[minute] in the time picker that is open, by typing them
  /// in rather than by turning the dial.
  Future<void> pickTime(
    WidgetTester tester,
    String hour,
    String minute,
  ) async {
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fields.at(0), hour);
    await tester.enterText(fields.at(1), minute);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

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

  testWidgets('moving the start leaves the end where the user put it',
      (tester) async {
    final window = await windowNamed('Night shift', {
      1: (startMinute: 22 * 60, endMinute: 2 * 60),
    });

    await tester.pumpWidget(harness(window: window));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('22:00'), findsOneWidget);
    expect(find.text('02:00'), findsOneWidget);

    // Move the start to 21:30. The window runs past midnight, so the end
    // stays at 02:00 and the row still says "next day".
    await tester.tap(find.byKey(const Key('time_window_start')));
    await tester.pumpAndSettle();
    await pickTime(tester, '9', '30');

    expect(find.text('21:30'), findsOneWidget);
    expect(find.text('02:00'), findsOneWidget);
    expect(find.text('next day'), findsOneWidget);
  });

  testWidgets('the end picker opens on a window that ends at midnight',
      (tester) async {
    final window = await windowNamed('Store hours', {
      1: (startMinute: 9 * 60, endMinute: 24 * 60),
    });

    await tester.pumpWidget(harness(window: window));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 24:00 is a valid value but not a clock the picker can show.
    expect(find.text('24:00'), findsOneWidget);
    await tester.tap(find.byKey(const Key('time_window_end')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'the end picker opens on a window that ends at midnight');
  });

  testWidgets('a second Save does not write a second window', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const Key('time_window_name')), 'Store hours');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('time_window_day_1')));
    await tester.pumpAndSettle();

    // Two activations in a row, as a double tap on a slow device gives. The
    // button is called directly so that both land while the first write is
    // still running.
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('time_window_save')),
    );
    save.onPressed!();
    save.onPressed!();
    await settle(tester);

    final windows = await db.select(db.timeWindows).get();
    expect(windows, hasLength(1));
  });

  testWidgets('Delete is disabled while a write is running', (tester) async {
    final window = await windowNamed('Store hours', {
      1: (startMinute: 9 * 60, endMinute: 17 * 60),
    });

    await tester.pumpWidget(harness(window: window));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('time_window_delete')))
          .onPressed,
      isNotNull,
      reason: 'Delete works when no write is running',
    );

    // The write is called directly, so that it is still running when the
    // Delete control is looked at. A Delete beside a running write would
    // open its confirmation on the same navigator, and the save's own pop
    // would take the dialog instead of the sheet.
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('time_window_save')),
    );
    save.onPressed!();
    await tester.pump();

    expect(
      find.byKey(const Key('time_window_delete')),
      findsOneWidget,
      reason: 'the sheet is still open while the write runs',
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('time_window_delete')))
          .onPressed,
      isNull,
      reason: 'Delete must not run beside a write in progress',
    );
  });

  testWidgets('the hours-only editor answers the hours and writes no window',
      (tester) async {
    TimeWindowHours? answer;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  answer = await showTimeWindowHoursSheet(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Hours alone need no name, and there is nothing to delete.
    expect(find.byKey(const Key('time_window_name')), findsNothing);
    expect(find.byKey(const Key('time_window_delete')), findsNothing);

    await tester.tap(find.byKey(const Key('time_window_day_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('time_window_save')));
    await settle(tester);

    // The hours came back, and no time window was written.
    expect(answer, isNotNull);
    expect(answer!.hoursForDay(1), (startMinute: 9 * 60, endMinute: 17 * 60));
    final windows =
        await tester.runAsync(() => db.select(db.timeWindows).get());
    expect(windows, isEmpty);
  });

  testWidgets('switching to the same hours applies them to every day',
      (tester) async {
    final window = await windowNamed('Store hours', {
      1: (startMinute: 9 * 60, endMinute: 17 * 60),
      2: (startMinute: 10 * 60, endMinute: 18 * 60),
    });

    await tester.pumpWidget(harness(window: window));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Different hours by day: the editor opens on the day-by-day one.
    await tester.tap(find.byKey(const Key('time_window_mode_same')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('time_window_save')));
    await settle(tester);

    // The sheet showed one pair for both days, so that is what it wrote.
    final saved = (await db.select(db.timeWindows).getSingle()).hours;
    final hours = TimeWindowHours.tryParse(saved)!;
    expect(hours.hoursForDay(1), (startMinute: 9 * 60, endMinute: 17 * 60));
    expect(hours.hoursForDay(2), (startMinute: 9 * 60, endMinute: 17 * 60));
  });
}
