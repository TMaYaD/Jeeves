/// The **Task Review queue** journey (#695, #704), end to end over a real store.
///
/// A user plans a day, works a Focus session, and closes the day at Evening
/// Shutdown. The next morning's Daily Planning Task Review step must ask only
/// about Outcomes that really need re-clarifying: closing the day must not, by
/// itself, put everything that was in the Plan back in the queue, and an
/// Outcome the user already re-clarified after finishing its Action must not
/// come back either. An Outcome whose Action finished and was never
/// re-clarified (**Stale**) still does.
///
/// Every write goes through the production seams — `ClarificationService` for
/// the Focus-session verdicts and `EveningShutdownNotifier.closeDay` for the
/// close — so the journey is evidence about the real flow. Per
/// docs/TESTING.md the store is staged in `setUp`.
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/routing_kind.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart'
    show eveningShutdownProvider;
import 'package:jeeves/services/clarification_service.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

Future<void> _insertOutcome(
  GtdDatabase db, {
  required String id,
  required String title,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value(title),
        clarified: const Value(true),
        intent: const Value('next'),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  await seedCurrentAction(db,
      outcomeId: id, text: 'work on $title', userId: _userId);
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ClarificationService clarification;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    clarification = DaoClarificationService(db);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<Set<String>> reviewQueueIds() async =>
      (await db.todoDao.getNeedsReview(actionlessReviewCutoff: actionlessGateOpenCutoff)).map((t) => t.id).toSet();

  Future<void> closeDayReturningToNext(Iterable<String> ids) async {
    final notifier = container.read(eveningShutdownProvider.notifier);
    await notifier.loadUnfinishedSnapshot();
    for (final id in ids) {
      notifier.returnToNext(id);
    }
    await notifier.closeDay();
  }

  test('an Outcome that rolled over untouched is not in the next morning\'s '
      'queue (#695)', () async {
    await _insertOutcome(db, id: 'rolled', title: 'Renew the passport');
    await db.focusSessionDao
        .openSession(userId: _userId, taskIds: ['rolled']);
    expect(await reviewQueueIds(), isEmpty,
        reason: 'precondition: planned with a current Action, not Stale');

    await closeDayReturningToNext(['rolled']);

    expect(await reviewQueueIds(), isNot(contains('rolled')),
        reason: 'closing the day must not make an untouched Outcome '
            'Stale — nothing about it changed');
  });

  test('after the Action finishes, a re-clarified Outcome is absent, a '
      'dismissed one stays Stale, an untouched one is absent (#704)',
      () async {
    await _insertOutcome(db, id: 'resolved', title: 'Draft the proposal');
    await _insertOutcome(db, id: 'dismissed', title: 'Chase the invoice');
    await _insertOutcome(db, id: 'untouched', title: 'Book the venue');
    final sessionId = await db.focusSessionDao.openSession(
        userId: _userId, taskIds: ['resolved', 'dismissed', 'untouched']);

    await db.focusSessionDao
        .setCurrentTask(sessionId: sessionId, taskId: 'resolved');
    await clarification.completeCurrentAction('resolved');
    await clarification.clarifyToOutcome(
      'resolved',
      to: RoutingKind.nextAction,
      actionText: 'send it to Trixy for review',
      userId: _userId,
    );

    await db.focusSessionDao
        .setCurrentTask(sessionId: sessionId, taskId: 'dismissed');
    // The user finishes the Action, then dismisses the re-clarify sheet.
    await clarification.completeCurrentAction('dismissed');

    await closeDayReturningToNext(['dismissed', 'untouched']);

    final queue = await reviewQueueIds();
    expect(queue, isNot(contains('resolved')),
        reason: 'the user already gave the verdict; close must not undo it');
    expect(queue, contains('dismissed'),
        reason: 'its Action finished and was never re-clarified: Stale');
    expect(queue, isNot(contains('untouched')));
  });
}
