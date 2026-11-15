/// Waiting For follow-up date journey (#692), over a real in-memory store.
///
/// Routing an Outcome to Waiting For with a "follow up from" date stores the
/// date as the `from` of the current Action's TimeContext (never as a due date).
/// The Outcome stays under Waiting For, leaves the Next List and Daily
/// Planning's Up Next until that date, and returns by itself. No date: nothing
/// changes. Provider plus real DB, no widgets (docs/TESTING.md: a live Drift
/// `watch()` hangs under widget-test fake time); the picker row has its own
/// widget test.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/follow_up_change.dart';
import 'package:jeeves/models/routing_kind.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/gtd_lists_provider.dart';
import 'package:jeeves/providers/time_context_provider.dart';
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;
  late DateTime Function() clock;
  late String alice;

  void startContainer() {
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWith((ref) => () => clock()),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    alice = await db.tagDao.createPersonTag('Alice', _userId);
    clock = () => DateTime(2026, 11, 11, 12);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<T> eventually<T>(
    ProviderListenable<T> provider,
    bool Function(T) done,
  ) async {
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 800; i++) {
      final value = sub.read();
      if (done(value)) return value;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return sub.read();
  }

  Future<Set<String>> ids(
    ProviderListenable<AsyncValue<List<Todo>>> provider,
    bool Function(Set<String>) done,
  ) async {
    final value = await eventually<AsyncValue<List<Todo>>>(
      provider,
      (v) => v.hasValue && done({for (final t in v.value!) t.id}),
    );
    return {for (final t in value.value ?? const <Todo>[]) t.id};
  }

  Future<String> clarifyToWaitingFor({
    required String captureId,
    required String title,
    FollowUpChange? followUp,
  }) async {
    final now = DateTime.now();
    await db.captureDao.insertCapture(CapturesCompanion(
      id: Value(captureId),
      title: Value(title),
      captureSource: const Value('manual'),
      userId: const Value(_userId),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    return DaoClarificationService(db).clarifyCaptureToOutcome(
      captureId,
      to: RoutingKind.waitingFor,
      userId: _userId,
      title: title,
      personTagIds: {alice},
      followUp: followUp,
    );
  }

  test('a follow-up date hides the Waiting For Outcome from Next and Up Next '
      'until the day starts, then it returns with no other write', () async {
    // Calendar-date arithmetic: `+ 24h` is still today in the first hour of a
    // fall-back DST day.
    final today = DateTime.now();
    final midnight = DateTime(today.year, today.month, today.day + 1);
    clock = () => midnight.subtract(const Duration(hours: 1));
    startContainer();

    final outcomeId = await clarifyToWaitingFor(
      captureId: 'c1',
      title: 'Contract from Alice',
      followUp: FollowUpChange.set(midnight),
    );

    final outcome = (await db.todoDao.getTodo(outcomeId))!;
    expect(outcome.dueDate, isNull, reason: 'not an Outcome due date');
    final action = (await db.actionDao.getCurrentAction(outcomeId))!;
    expect(action.actionText, 'Contract from Alice',
        reason: 'an Actionless Outcome gets its title as the Action');
    expect(TimeContext.tryParse(action.timeContext)!.fromDate, midnight);

    // Still under Waiting For.
    final waiting = await ids(
        waitingForProvider, (v) => v.contains(outcomeId));
    expect(waiting, contains(outcomeId));
    // Off Next and off Up Next.
    expect(await ids(nextProvider, (v) => !v.contains(outcomeId)), isEmpty);
    expect(
        await ids(nextForFocusSessionPlanningProvider,
            (v) => !v.contains(outcomeId)),
        isEmpty);

    // Only now start the real elapsed time, 2 s before midnight, and re-arm the
    // boundary timer against the new clock.
    final stopwatch = Stopwatch()..start();
    final start = midnight.subtract(const Duration(milliseconds: 2000));
    clock = () => start.add(stopwatch.elapsed);
    container.invalidate(timeContextBoundaryTickProvider);
    expect(await ids(nextProvider, (v) => v.contains(outcomeId)), {outcomeId});
    expect(
        await ids(nextForFocusSessionPlanningProvider,
            (v) => v.contains(outcomeId)),
        {outcomeId});
    expect(await ids(waitingForProvider, (v) => v.contains(outcomeId)),
        contains(outcomeId));
  });

  test('no follow-up date: nothing is written and the Outcome is on Next at '
      'once, as before', () async {
    startContainer();
    final outcomeId = await clarifyToWaitingFor(
      captureId: 'c1',
      title: 'Plain wait',
    );
    // The routing carved no Action (intent-only), so give it one the way a
    // user would, and check the Action carries no TimeContext.
    expect(await db.actionDao.getCurrentAction(outcomeId), isNull);
    await seedCurrentAction(db,
        outcomeId: outcomeId, text: 'Chase', userId: _userId);
    expect((await db.actionDao.getCurrentAction(outcomeId))!.timeContext,
        isNull);
    expect(await ids(nextProvider, (v) => v.contains(outcomeId)), {outcomeId});
  });

  test('an Actionless Outcome re-routed with a date gets its title as the '
      'Action; removing the date later restores the weekly window only',
      () async {
    startContainer();
    final outcomeId = await clarifyToWaitingFor(
      captureId: 'c1',
      title: 'Reply from Alice',
    );
    final service = DaoClarificationService(db);
    await service.clarifyToOutcome(
      outcomeId,
      to: RoutingKind.waitingFor,
      personTagIds: {alice},
      userId: _userId,
      followUp: FollowUpChange.set(DateTime(2027, 1, 15)),
    );
    var action = (await db.actionDao.getCurrentAction(outcomeId))!;
    expect(action.actionText, 'Reply from Alice');
    expect(action.timeContext, '{"from":"2027-01-15"}');

    // A weekly window set by hand survives a date change and a removal.
    await db.actionDao.setTimeContext(
        action.id,
        TimeContext.create(
            fromDate: DateTime(2027, 1, 15), days: {2}, startMinute: 540,
            endMinute: 1020));
    await service.clarifyToOutcome(
      outcomeId,
      to: RoutingKind.waitingFor,
      followUp: FollowUpChange.set(DateTime(2027, 2, 1)),
    );
    action = (await db.actionDao.getCurrentAction(outcomeId))!;
    expect(TimeContext.tryParse(action.timeContext)!.fromDate,
        DateTime(2027, 2, 1));
    expect(TimeContext.tryParse(action.timeContext)!.days, {2});

    await service.clarifyToOutcome(
      outcomeId,
      to: RoutingKind.waitingFor,
      followUp: const FollowUpChange.remove(),
    );
    action = (await db.actionDao.getCurrentAction(outcomeId))!;
    final remaining = TimeContext.tryParse(action.timeContext)!;
    expect(remaining.fromDate, isNull);
    expect(remaining.days, {2});
  });

  test('followUp is refused for any destination but Waiting For', () async {
    await db.todoDao.insertOutcome(id: 'o1', title: 'x', userId: _userId);
    expect(
      () => db.todoDao.applyRouting('o1',
          to: RoutingKind.nextAction, followUp: FollowUpChange.set(DateTime(2027))),
      throwsArgumentError,
    );
  });
}
