/// The Weekly Review says when each Outcome's time opens in the coming week
/// (GitHub #1073).
///
/// Over a real in-memory store and the real review screen: the review's Next
/// step shows one card at a time, and each card carries a line saying when
/// that Outcome's time opens in the seven days starting on the day of the
/// review.
///
/// Two harness rules this file obeys (docs/TESTING.md):
///
/// * **The store is built outside the fake zone.** A widget-test body runs
///   under `FakeAsync`, which cannot advance a real `NativeDatabase` round
///   trip, so a store built inside one never finishes its first write. The
///   staging runs through `tester.runAsync`.
/// * **The container is disposed in that same real zone**, so Drift's cleanup
///   timers can finish before Flutter checks for pending timers.
/// * **The synced preferences are built outside the fake zone too.** The
///   Weekly Review's snapshot loaders await them, and their migration cannot
///   run inside the fake zone, so the provider is built here and kept alive
///   for the scenario.
/// * **The Next list is read in the real zone.** The list's own provider is
///   read to show that an Outcome whose window is closed is off the Next
///   list while the Weekly Review still shows it, and a listener is held
///   while its first value arrives.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/providers/time_context_provider.dart';
import 'package:jeeves/providers/time_window_provider.dart';
import 'package:jeeves/screens/periodic_review/periodic_review_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/outcome_review_card.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// Sunday 2026-11-29, noon. The coming week is Sun 29 Nov … Sat 5 Dec.
final DateTime _now = DateTime(2026, 11, 29, 12);

/// The store and the container one scenario runs against.
class _Scenario {
  _Scenario(this.db, this.container, this.preferences);

  final GtdDatabase db;
  final ProviderContainer container;

  /// The listener that keeps the synced preferences alive.
  final ProviderSubscription<AsyncValue<SyncedPreferences>> preferences;

  /// Disposes the container and closes the store. Called in the real async
  /// zone: a Drift subscription's cleanup timers must be able to finish.
  Future<void> dispose() async {
    preferences.close();
    container.dispose();
    await db.close();
  }
}

/// Builds the store, seeds it and makes the container — outside the fake
/// zone, where a real database round trip can complete.
Future<_Scenario> _stage(
  WidgetTester tester, {
  required Future<void> Function(GtdDatabase db) seed,
  DateTime Function()? clock,
}) async {
  final scenario = await tester.runAsync(() async {
    final db = GtdDatabase(NativeDatabase.memory());
    await seed(db);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider
          .overrideWithValue(StubPeriodicReviewNotificationService()),
      clockProvider.overrideWith((ref) => clock ?? () => _now),
    ]);
    // The Weekly Review's snapshot loaders await the synced preferences, and
    // their migration cannot run inside the fake zone. Build the provider
    // here, in the real zone, and keep a listener so it stays alive for the
    // rest of the scenario (docs/TESTING.md).
    final preferences =
        container.listen(syncedPreferencesProvider, (_, _) {});
    await container.read(syncedPreferencesProvider.future);
    return _Scenario(db, container, preferences);
  });
  expect(scenario, isNotNull, reason: 'the store could not be staged');
  return scenario!;
}

/// Unmounts the screen and disposes the store, the disposal in the real async
/// zone.
Future<void> _teardown(WidgetTester tester, _Scenario scenario) async {
  // Unmount first: a widget must not read a disposed container.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.runAsync(() => scenario.dispose());
}

/// The ids the Next list shows, read through the Next list's own provider.
///
/// The list filters on the named windows and the Time contexts, so those are
/// loaded first: the list's first value would otherwise predate them and
/// show every Outcome. A listener is held while each first value arrives — a
/// `StreamProvider`'s future does not survive a bare `container.read`
/// (docs/TESTING.md). Call this in the real async zone, where the list's
/// watch can run.
Future<Set<String>> _nextIds(ProviderContainer container) async {
  final windows = container.listen(currentTimeWindowsProvider, (_, _) {});
  final contexts = container.listen(currentTimeContextsProvider, (_, _) {});
  try {
    await container.read(currentTimeWindowsProvider.future);
    await container.read(currentTimeContextsProvider.future);
    final subscription = container.listen(nextProvider, (_, _) {});
    try {
      await container.read(nextProvider.future);
      final value = container.read(nextProvider);
      return {for (final todo in value.value ?? const <Todo>[]) todo.id};
    } finally {
      subscription.close();
    }
  } finally {
    windows.close();
    contexts.close();
  }
}

/// An Outcome on Next with a current Action, created at [createdAt] so the
/// snapshot's order is the order of the fixtures.
Future<String> _insertOutcome(
  GtdDatabase db, {
  required String id,
  required String title,
  required DateTime createdAt,
  String? actionText,
}) async {
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(createdAt),
        updatedAt: Value(createdAt),
      ));
  await seedCurrentAction(
    db,
    outcomeId: id,
    text: actionText ?? 'work on $title',
    userId: _userId,
    createdAt: createdAt,
  );
  return (await db.actionDao.getCurrentAction(id))!.id;
}

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the Next step says when each Outcome\'s time opens in the '
      'coming week', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final scenario = await _stage(tester, seed: (db) async {
      // A named window that opens on Wednesday of the coming week. It is
      // closed at the review's clock, so the Outcome is hidden from the Next
      // List — the review still shows it, now with the line that says when it
      // opens.
      final windowId = await db.timeWindowDao.createTimeWindow(
        name: 'Dance class',
        hours: {
          3: (startMinute: 16 * 60, endMinute: 20 * 60),
        },
        userId: _userId,
      );
      final danceAction = await _insertOutcome(
        db,
        id: 'dance',
        title: 'Dance class',
        createdAt: DateTime(2026, 11, 1, 9),
      );
      await db.actionDao.setTimeWindow(danceAction, windowId);

      // A one-time time on the same Wednesday.
      final onceAction = await _insertOutcome(
        db,
        id: 'once',
        title: 'Book the dentist',
        createdAt: DateTime(2026, 11, 1, 10),
      );
      await db.actionDao.setTimeContext(
        onceAction,
        TimeContext.create(
          days: {3},
          startMinute: 16 * 60,
          endMinute: 20 * 60,
        ),
      );

      // A time that only starts on a date inside the coming week.
      final fromAction = await _insertOutcome(
        db,
        id: 'from',
        title: 'Renew the passport',
        createdAt: DateTime(2026, 11, 1, 11),
      );
      await db.actionDao.setTimeContext(
        fromAction,
        TimeContext.create(fromDate: DateTime(2026, 12, 2)),
      );

      // A time that starts beyond the coming week: the card reads as it does
      // today, with no line.
      final laterAction = await _insertOutcome(
        db,
        id: 'later',
        title: 'Plan the summer',
        createdAt: DateTime(2026, 11, 1, 12),
      );
      await db.actionDao.setTimeContext(
        laterAction,
        TimeContext.create(fromDate: DateTime(2026, 12, 10)),
      );

      // An Outcome with no time at all: it stays on the Next list, so the
      // list is not empty for a reason of its own.
      await _insertOutcome(
        db,
        id: 'plain',
        title: 'Renew the car tax',
        createdAt: DateTime(2026, 11, 1, 13),
      );
    });

    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: scenario.container,
        child: const MaterialApp(home: PeriodicReviewScreen()),
      ));
      await settleWithRealAsync(tester);

      await tester.runAsync(() async {
        await scenario.container
            .read(periodicReviewProvider.notifier)
            .goToStep(PeriodicReviewNotifier.kStepNext);
      });
      // The wizard animates to the Next step; a plain pump avoids waiting on a
      // settle that a step animation would keep open.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The first card: the named window, named and dated.
      await _pumpUntilFound(
        tester,
        find.text('Dance class · Wed 16:00–20:00'),
      );
      expect(find.text('Dance class · Wed 16:00–20:00'), findsOneWidget);

      // The Outcome is hidden from the Next list — its window is closed at the
      // review's clock — and the Weekly Review still shows it, with the line
      // that says when it opens (issue #1073). The Next list is otherwise
      // working: it shows the Outcome that carries no time.
      final nextIds =
          (await tester.runAsync(() => _nextIds(scenario.container)))!;
      expect(nextIds, contains('plain'),
          reason: 'the Next list shows the Outcome that carries no time');
      expect(nextIds, isNot(contains('dance')),
          reason: 'a closed window hides the Outcome from the Next list');

      // The line is plain text: it names the day, it does not book it.
      await _expectNoTapTarget(tester);
      expect(find.text('Keep'), findsOneWidget);
      expect(find.text('Re-clarify…'), findsOneWidget);

      // The second card: a one-time time, with no window name.
      await _tapKeep(tester);
      await _pumpUntilFound(tester, find.text('Wed 16:00–20:00'));
      expect(find.text('Wed 16:00–20:00'), findsOneWidget);

      // The third card: a time that only has a from-date.
      await _tapKeep(tester);
      await _pumpUntilFound(tester, find.text('From Wed 2 Dec'));
      expect(find.text('From Wed 2 Dec'), findsOneWidget);

      // The fourth card: a time beyond the coming week carries no line.
      await _tapKeep(tester);
      await _pumpUntilFound(tester, find.text('Plan the summer'));
      expect(find.text('Plan the summer'), findsOneWidget);
      expect(find.byKey(const Key('coming-week-time')), findsNothing);
    } finally {
      await _teardown(tester, scenario);
    }
  });

  testWidgets('the card\'s Action text and its time line describe the same '
      'Action', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    String? plannedId;
    final scenario = await _stage(tester, seed: (db) async {
      // The current Action, with a named window of its own.
      final danceWindow = await db.timeWindowDao.createTimeWindow(
        name: 'Dance class',
        hours: {
          3: (startMinute: 16 * 60, endMinute: 20 * 60),
        },
        userId: _userId,
      );
      // The successor: a planned Action with a window of its own.
      final gymWindow = await db.timeWindowDao.createTimeWindow(
        name: 'Gym',
        hours: {
          4: (startMinute: 9 * 60, endMinute: 10 * 60),
        },
        userId: _userId,
      );
      final currentAction = await _insertOutcome(
        db,
        id: 'dance',
        title: 'Dance class',
        actionText: 'Book the class',
        createdAt: DateTime(2026, 11, 1, 9),
      );
      await db.actionDao.setTimeWindow(currentAction, danceWindow);
      await db.actionDao.addPlannedAction('dance', 'Attend the class');
      final planned = (await db.actionDao.getPlannedActions('dance')).single;
      plannedId = planned.id;
      await db.actionDao.setTimeWindow(planned.id, gymWindow);
    });

    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: scenario.container,
        child: const MaterialApp(home: PeriodicReviewScreen()),
      ));
      await settleWithRealAsync(tester);

      await tester.runAsync(() async {
        await scenario.container
            .read(periodicReviewProvider.notifier)
            .goToStep(PeriodicReviewNotifier.kStepNext);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await _pumpUntilFound(tester, find.text('Book the class'));
      expect(find.text('Dance class · Wed 16:00–20:00'), findsOneWidget);

      // The current Action is replaced while the review is open — the planned
      // Action is promoted. The card must show the successor's words beside the
      // successor's time: never the retired Action's words beside the
      // successor's time.
      await tester.runAsync(() async {
        await scenario.db.actionDao.supersedeAndPromote(plannedId!);
      });
      await _pumpUntilFound(tester, find.text('Attend the class'));

      expect(find.text('Book the class'), findsNothing);
      expect(find.text('Gym · Thu 09:00–10:00'), findsOneWidget);
    } finally {
      await _teardown(tester, scenario);
    }
  });

  testWidgets('the lines follow the clock when the review is built again',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var now = _now;
    final scenario = await _stage(
      tester,
      clock: () => now,
      seed: (db) async {
        // A time that only starts on a date inside the coming week.
        final fromAction = await _insertOutcome(
          db,
          id: 'from',
          title: 'Renew the passport',
          createdAt: DateTime(2026, 11, 1, 11),
        );
        await db.actionDao.setTimeContext(
          fromAction,
          TimeContext.create(fromDate: DateTime(2026, 12, 2)),
        );
      },
    );

    try {
      await tester.pumpWidget(UncontrolledProviderScope(
        container: scenario.container,
        child: const MaterialApp(home: PeriodicReviewScreen()),
      ));
      await settleWithRealAsync(tester);

      await tester.runAsync(() async {
        await scenario.container
            .read(periodicReviewProvider.notifier)
            .goToStep(PeriodicReviewNotifier.kStepNext);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // Sunday 29 Nov: the from-date falls inside the coming week.
      await _pumpUntilFound(tester, find.text('From Wed 2 Dec'));
      expect(find.text('From Wed 2 Dec'), findsOneWidget);

      // The clock moves past the from-date, and the ceremony is built again —
      // a second review in the same session.
      now = DateTime(2026, 12, 3, 12);
      await tester.runAsync(() async {
        final notifier =
            scenario.container.read(periodicReviewProvider.notifier);
        await notifier.finishSession();
        await notifier.goToStep(PeriodicReviewNotifier.kStepNext);
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The rebuilt review reads the clock again: the from-date has passed,
      // so the card carries no line.
      await _pumpUntilGone(tester, find.byKey(const Key('coming-week-time')));
      expect(find.byKey(const Key('coming-week-time')), findsNothing);
      expect(find.text('Renew the passport'), findsOneWidget);
    } finally {
      await _teardown(tester, scenario);
    }
  });
}

/// Taps the Keep action, which advances the step's cursor to the next item.
Future<void> _tapKeep(WidgetTester tester) async {
  final keep = find.text('Keep');
  await tester.ensureVisible(keep);
  await tester.tap(keep);
  // Keep writes to the store, and the cursor advances once the write has
  // landed: the write needs the real event loop.
  await tester.runAsync(() => pumpEventQueue());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Pumps until [finder] matches something, so the drift-fed windows and Time
/// contexts have a chance to arrive.
Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets, reason: 'the line never appeared');
}

/// Pumps until [finder] matches nothing, so a line that has gone has had the
/// chance to.
Future<void> _pumpUntilGone(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isEmpty) return;
  }
}

/// The coming-week line carries no tap target of its own: nothing inside the
/// card picks a day.
Future<void> _expectNoTapTarget(WidgetTester tester) async {
  final row = find.byKey(const Key('coming-week-time'));
  expect(row, findsOneWidget);
  final element = tester.element(row);
  Element? cardElement;
  element.visitAncestorElements((ancestor) {
    if (ancestor.widget is OutcomeReviewCard) {
      cardElement = ancestor;
      return false;
    }
    return true;
  });
  expect(cardElement, isNotNull, reason: 'the line sits on the review card');
  var tapTarget = false;
  element.visitAncestorElements((ancestor) {
    if (ancestor == cardElement) return false;
    final widget = ancestor.widget;
    if (widget is InkWell ||
        widget is InkResponse ||
        widget is GestureDetector ||
        widget is TextButton ||
        widget is OutlinedButton ||
        widget is ElevatedButton ||
        widget is IconButton) {
      tapTarget = true;
    }
    return true;
  });
  expect(tapTarget, isFalse, reason: 'the line is plain text');
}
