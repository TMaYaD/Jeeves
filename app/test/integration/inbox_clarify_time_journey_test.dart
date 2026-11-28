/// The clarify card's Time chip journey (issue #1093), over a real in-memory
/// store.
///
/// The user clarifies an Inbox Capture and says when the Action that
/// clarification creates can be done. The Outcome lands with that time: off
/// the Next list while a named window is closed, and on the time page.
///
/// The Capture itself is never written: it stays the raw record of what was
/// captured, title, notes and tag hints alike.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Action;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/providers/time_page_provider.dart';
import 'package:jeeves/router.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// Settles the tree and lets real async work finish.
///
/// The Inbox and the clarify screen read live drift streams, so
/// `pumpAndSettle` never reaches a quiet frame — a bounded drain is what the
/// other journeys over these very screens use (docs/TESTING.md).
Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late String workHoursId;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('c1'),
      title: const Value('Buy hinges'),
      notes: const Value('The long ones'),
      userId: const Value(_userId),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    // A tag hint the clarification must leave alone.
    final area = await db.tagDao.findOrCreateTag('Home', 'area', _userId);
    await db.captureDao.assignTagHint('c1', area, _userId);

    workHoursId = (await db.timeWindowDao.createTimeWindow(
      name: 'Work hours',
      hours: {
        for (var day = 1; day <= 5; day++)
          day: (startMinute: 9 * 60, endMinute: 17 * 60),
      },
      userId: _userId,
    ))!;

    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      // 2026-11-14 is a Saturday: Work hours is closed.
      clockProvider.overrideWith((ref) => () => DateTime(2026, 11, 14, 12)),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    await container.read(syncedPreferencesProvider.future);
  });

  tearDown(() async {
    await db.close();
  });

  /// The Inbox, then the Capture's clarify screen — the real route.
  Future<void> openClarify(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    appRouter.go('/inbox');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: appRouter),
      ),
    );
    await _settle(tester);

    await tester.tap(find.text('Buy hinges'));
    await _settle(tester);
  }

  /// Takes the app off screen and lets the watches behind it close.
  ///
  /// The container goes with it: a drift watch left open when the tree goes
  /// leaves a timer pending, and the *next* test would pay for it
  /// (docs/TESTING.md).
  Future<void> closeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump(const Duration(milliseconds: 10));
  }

  /// Scrolls the Time chip into view and opens the time sheet.
  ///
  /// The chip sits below the fold and a ListView builds its children lazily,
  /// so the drag comes first: the chip has to exist before it can be tapped.
  Future<void> openTimeChip(WidgetTester tester) async {
    final chip = find.byKey(const Key('clarify_time_chip'));
    for (var i = 0; i < 15 && chip.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(chip, findsOneWidget,
        reason: 'the Time chip never came into view');
    await tester.ensureVisible(chip);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(chip);
    await _settle(tester);
  }

  /// Routes the Capture to Next, accepting the dialog's seeded phrase.
  Future<void> routeToNext(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Next Action'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.ensureVisible(find.text('Next Action'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('Next Action'));
    await _settle(tester);
    await tester.tap(find.text('Save'));
    await _settle(tester);
  }

  /// Waits for a provider to answer, on the real event loop.
  Future<T> eventually<T>(
    WidgetTester tester,
    ProviderListenable<T> provider,
    bool Function(T) done,
  ) async {
    final sub = container.listen(provider, (_, _) {});
    try {
      for (var i = 0; i < 800; i++) {
        final value = sub.read();
        if (done(value)) return value;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      return sub.read();
    } finally {
      sub.close();
    }
  }

  /// The Outcome the clarification created.
  Future<String> outcomeId(WidgetTester tester) async {
    final ids = await tester.runAsync(
      () => db.captureDao.outcomeIdsForCapture('c1'),
    );
    return ids!.single;
  }

  /// The Outcome's current Action.
  Future<Action> currentAction(WidgetTester tester, String id) async {
    final action = await tester.runAsync(
      () => db.actionDao.getCurrentAction(id),
    );
    return action!;
  }

  /// The Capture, exactly as it was captured.
  Future<void> expectCaptureUntouched(WidgetTester tester) async {
    final result = await tester.runAsync(() async {
      final capture = await db.captureDao.getCapture('c1');
      final hints = await db.captureDao.tagHintsForCapture('c1');
      return (capture: capture, hints: hints);
    });
    final r = result!;
    expect(r.capture!.title, 'Buy hinges');
    expect(r.capture!.notes, 'The long ones');
    expect(r.hints.map((t) => t.name), contains('Home'),
        reason: 'the tag hints are the Capture\'s, not the Outcome\'s');
  }

  testWidgets('a named window on the clarify card puts it on the Action',
      (tester) async {
    await openClarify(tester);
    try {
      await openTimeChip(tester);
      await tester.tap(find.byKey(const Key('time_context_choice_window')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('time_context_window_$workHoursId')));
      await _settle(tester);

      expect(find.text('Work hours'), findsOneWidget,
          reason: 'the chip names the window the user chose');

      await routeToNext(tester);

      final id = await outcomeId(tester);
      final action = await currentAction(tester, id);
      expect(action.timeWindowId, workHoursId);
      expect(action.timeContext, isNull);
      await expectCaptureUntouched(tester);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('an Outcome in a closed window leaves Next and shows on the '
      'time page', (tester) async {
    await openClarify(tester);
    try {
      await openTimeChip(tester);
      await tester.tap(find.byKey(const Key('time_context_choice_window')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('time_context_window_$workHoursId')));
      await _settle(tester);

      await routeToNext(tester);

      final id = await outcomeId(tester);
      final groups = await eventually<AsyncValue<List<TimePageGroup>>>(
        tester,
        timePageGroupsProvider,
        (v) =>
            v.hasValue && v.value!.any((g) => g.rows.any((r) => r.todo.id == id)),
      );
      final group = groups.value!
          .firstWhere((g) => g.rows.any((r) => r.todo.id == id));
      expect(group.title, 'Work hours');
      expect(group.rows.firstWhere((r) => r.todo.id == id).isOnNext, isFalse,
          reason: 'it is Saturday and Work hours is Monday to Friday');

      final next = await eventually<AsyncValue<List<Todo>>>(
        tester,
        nextProvider,
        (v) => v.hasValue && !v.value!.any((t) => t.id == id),
      );
      expect(next.value!.map((t) => t.id), isNot(contains(id)));
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a one-time time can be set from the clarify step',
      (tester) async {
    await openClarify(tester);
    try {
      await openTimeChip(tester);
      await tester.tap(find.byKey(const Key('time_context_choice_one_time')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('time_context_day_6')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('time_context_save')));
      await _settle(tester);

      await routeToNext(tester);

      final id = await outcomeId(tester);
      final action = await currentAction(tester, id);
      expect(TimeContext.tryParse(action.timeContext),
          TimeContext.create(days: {6}));
      expect(action.timeWindowId, isNull);
      await expectCaptureUntouched(tester);
    } finally {
      await closeApp(tester);
    }
  });

  testWidgets('a chip left empty clarifies as today, with no time',
      (tester) async {
    await openClarify(tester);
    try {
      await routeToNext(tester);

      final id = await outcomeId(tester);
      final action = await currentAction(tester, id);
      expect(action.timeWindowId, isNull);
      expect(action.timeContext, isNull);

      final next = await eventually<AsyncValue<List<Todo>>>(
        tester,
        nextProvider,
        (v) => v.hasValue && v.value!.any((t) => t.id == id),
      );
      expect(next.value!.map((t) => t.id), contains(id),
          reason: 'an Outcome with no time is on Next as it always was');
      await expectCaptureUntouched(tester);
    } finally {
      await closeApp(tester);
    }
  });
}
