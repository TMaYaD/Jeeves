/// The Weekly Review says when each Outcome's time opens in the coming week
/// (GitHub #1073).
///
/// Over a real in-memory store and the real review screen: the review's Next
/// step shows one card at a time, and each card carries a line saying when
/// that Outcome's time opens in the seven days starting on the day of the
/// review.
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
import 'package:jeeves/providers/periodic_review_provider.dart';
import 'package:jeeves/screens/periodic_review/periodic_review_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/widgets/outcome_review_card.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../helpers/settle.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// Sunday 2026-11-29, noon. The coming week is Sun 29 Nov … Sat 5 Dec.
final DateTime _now = DateTime(2026, 11, 29, 12);

/// An Outcome on Next with a current Action, created at [createdAt] so the
/// snapshot's order is the order of the fixtures.
Future<String> _insertOutcome(
  GtdDatabase db, {
  required String id,
  required String title,
  required DateTime createdAt,
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
    text: 'work on $title',
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
    final db = GtdDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // A named window that opens on Wednesday of the coming week. It is closed
    // at the review's clock, so the Outcome is hidden from the Next List — the
    // review still shows it, now with the line that says when it opens.
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

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider
          .overrideWithValue(StubPeriodicReviewNotificationService()),
      clockProvider.overrideWith((ref) => () => _now),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: PeriodicReviewScreen()),
    ));
    await settleWithRealAsync(tester);

    await tester.runAsync(() async {
      await container
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
