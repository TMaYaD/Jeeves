/// Journey: a Waiting For Outcome's follow-up date (the `from` date of its
/// current Action's TimeContext) drives a notification at 09:00 local on that
/// date, through the real database and DAO write paths. The OS is replaced by
/// [_FakeOs], which keeps one pending set for both notification kinds and
/// answers each kind's device query from payload prefixes only — so these
/// tests prove what the app hands to the notification service and that the
/// follow-up and due-date reconcilers cannot cancel each other's entries, not
/// Android's alarm delivery.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/routing_kind.dart';
import 'package:jeeves/models/time_context.dart';
import 'package:jeeves/services/due_date_notifications.dart';
import 'package:jeeves/services/follow_up_notifications.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

class _Scheduled {
  _Scheduled(this.title, this.body, this.fireAt, this.payload);
  final String title;
  final String body;
  final DateTime fireAt;
  final String? payload;
}

class _FakeOs extends NotificationService {
  _FakeOs() : super.forTesting();

  final pending = <int, _Scheduled>{};

  /// Tray entries: id -> payload prefix of the kind that delivered it.
  final delivered = <int, String>{};

  @override
  Future<void> scheduleReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
    String? payload,
  }) async {
    pending[id] = _Scheduled(title, body, scheduledAt, payload);
  }

  @override
  Future<void> scheduleFollowUpNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledAt,
    String? payload,
  }) async {
    pending[id] = _Scheduled(title, body, scheduledAt, payload);
  }

  @override
  Future<void> cancelReminder(int id) async {
    pending.remove(id);
    delivered.remove(id);
  }

  OutcomeNotificationsOnDevice _query(String prefix) {
    final mine = {
      for (final e in pending.entries)
        if ((e.value.payload ?? '').startsWith(prefix)) e.key: e.value,
    };
    return (
      pending: mine.keys.toSet(),
      pendingFireAtMillis: {
        for (final e in mine.entries)
          if (outcomeNotificationFireAtMillis(prefix, e.value.payload) != null)
            e.key: outcomeNotificationFireAtMillis(prefix, e.value.payload)!,
      },
      delivered: {
        for (final e in delivered.entries)
          if (e.value == prefix) e.key,
      },
    );
  }

  @override
  Future<OutcomeNotificationsOnDevice> dueDateNotificationsOnDevice() async =>
      _query(kDueDateNotificationPayloadPrefix);

  @override
  Future<OutcomeNotificationsOnDevice> followUpNotificationsOnDevice() async =>
      _query(kFollowUpNotificationPayloadPrefix);

  @override
  Future<bool> refreshLocalTimezone() async => false;
}

void main() {
  setUpAll(() {
    configureSqliteForTests();
    tz_data.initializeTimeZones();
  });

  late tz.Location kolkata;
  late GtdDatabase db;
  late _FakeOs os;
  late OutcomeNotificationReconciler reconciler;
  late String alice;
  final now = DateTime.utc(2026, 11, 10, 6); // 11:30 in Kolkata.

  OutcomeNotificationReconciler startFollowUps() => OutcomeNotificationReconciler(
        notifications: os,
        kind: followUpNotificationKind,
        candidates: followUpNotificationCandidates(
          waitingForOutcomes: db.todoDao.watchPersonTagged(),
          currentTimeContexts: db.actionDao.watchCurrentTimeContexts(),
        ),
        now: () => now,
      )..start(listenToLifecycle: false);

  Future<void> settle([OutcomeNotificationReconciler? r]) async {
    for (var i = 0; i < 2; i++) {
      await pumpEventQueue();
      await (r ?? reconciler).settled();
    }
  }

  /// A Waiting For Outcome with a current Action, optionally with a follow-up.
  Future<String> waitingFor(String id, {DateTime? followUpFrom}) async {
    await db.todoDao.insertOutcome(id: id, title: 'Title $id', userId: 'local');
    await seedCurrentAction(db,
        outcomeId: id, text: 'chase $id', userId: 'local');
    await db.todoDao.applyRouting(id,
        to: RoutingKind.waitingFor, personTagIds: {alice}, userId: 'local');
    if (followUpFrom != null) {
      await db.actionDao.setTimeContext('action-$id',
          TimeContext.create(fromDate: followUpFrom));
    }
    return id;
  }

  bool at9(String id, int y, int m, int d) => os.pending[followUpNotificationId(id)]!
      .fireAt
      .isAtSameMomentAs(tz.TZDateTime(kolkata, y, m, d, 9));

  setUp(() async {
    kolkata = tz.getLocation('Asia/Kolkata');
    tz.setLocalLocation(kolkata);
    db = GtdDatabase(NativeDatabase.memory());
    alice = await db.tagDao.createPersonTag('Alice', 'local');
    os = _FakeOs();
    reconciler = startFollowUps();
  });

  tearDown(() async {
    reconciler.dispose();
    await db.close();
  });

  test('a follow-up date produces one notification at 09:00 on that date',
      () async {
    await waitingFor('a', followUpFrom: DateTime(2026, 11, 12));
    await settle();

    expect(os.pending, hasLength(1));
    final scheduled = os.pending[followUpNotificationId('a')]!;
    expect(scheduled.title, 'Title a');
    expect(scheduled.body, 'Follow up today');
    expect(scheduled.payload,
        followUpNotificationPayload('a', fireAt: scheduled.fireAt));
    expect(at9('a', 2026, 11, 12), isTrue);
  });

  test('changing the date replaces the notification', () async {
    await waitingFor('a', followUpFrom: DateTime(2026, 11, 12));
    await settle();
    await db.actionDao.setTimeContext(
        'action-a', TimeContext.create(fromDate: DateTime(2026, 11, 20)));
    await settle();

    expect(os.pending, hasLength(1));
    expect(at9('a', 2026, 11, 20), isTrue);
  });

  test('no follow-up date, or a weekly window alone, gets none', () async {
    await waitingFor('plain');
    await waitingFor('window');
    await db.actionDao.setTimeContext('action-window',
        TimeContext.create(days: {2}, startMinute: 540, endMinute: 1020));
    await settle();

    expect(os.pending, isEmpty);
  });

  test('an Outcome that is not waiting on anyone gets none', () async {
    await db.todoDao.insertOutcome(id: 'a', title: 'A', userId: 'local');
    await seedCurrentAction(db, outcomeId: 'a', text: 'x', userId: 'local');
    await db.todoDao.applyRouting('a', to: RoutingKind.nextAction);
    await db.actionDao.setTimeContext(
        'action-a', TimeContext.create(fromDate: DateTime(2026, 11, 12)));
    await settle();

    expect(os.pending, isEmpty);
  });

  test('completing the Action, removing the last Person, completing or '
      'trashing the Outcome each cancel it', () async {
    for (final cancel in <String, Future<void> Function(String)>{
      'completes the Action': (id) => db.actionDao.completeCurrentAction(id),
      'removes the last Person': (id) =>
          db.todoDao.setPersonTagsForTodo(id, <String>{}, 'local'),
      'completes the Outcome': (id) => db.todoDao.markDone(id),
      'trashes the Outcome': (id) =>
          db.todoDao.applyRouting(id, to: RoutingKind.trash),
    }.entries) {
      final id = 'o-${cancel.key.hashCode}';
      await waitingFor(id, followUpFrom: DateTime(2026, 11, 12));
      await settle();
      expect(os.pending, hasLength(1), reason: cancel.key);
      await cancel.value(id);
      await settle();
      expect(os.pending, isEmpty, reason: cancel.key);
    }
  });

  test('after a restart the pending set matches the database', () async {
    await waitingFor('keep', followUpFrom: DateTime(2026, 11, 12));
    await waitingFor('lost', followUpFrom: DateTime(2026, 11, 13));
    await settle();

    reconciler.dispose();
    os.pending.remove(followUpNotificationId('lost'));
    reconciler = startFollowUps();
    await settle();

    expect(os.pending.keys.toSet(), {
      followUpNotificationId('keep'),
      followUpNotificationId('lost'),
    });
  });

  test('a due-date and a follow-up notification for one Outcome coexist, and '
      'neither reconciler cancels the other\'s, pending or delivered',
      () async {
    final dueDay = DateTime.utc(2026, 11, 14);
    await waitingFor('a', followUpFrom: DateTime(2026, 11, 12));
    await db.todoDao.insertOutcome(
        id: 'd', title: 'Title d', userId: 'local', dueDate: dueDay);
    await db.todoDao.updateFields('a', dueDate: dueDay);
    final dueReconciler = DueDateNotificationReconciler(
      notifications: os,
      outcomes: db.todoDao.watchDueDateNotificationCandidates(),
      now: () => now,
    )..start(listenToLifecycle: false);
    addTearDown(dueReconciler.dispose);
    await settle();
    await settle(dueReconciler);

    expect(os.pending.keys.toSet(), {
      followUpNotificationId('a'),
      dueDateNotificationId('a'),
      dueDateNotificationId('d'),
    });
    expect(followUpNotificationId('a'), isNot(dueDateNotificationId('a')));

    // A stray tray entry of each kind (delivered earlier, not planned now). A
    // reconcile of one kind removes only its own kind's entry.
    os.delivered[900001] = kDueDateNotificationPayloadPrefix;
    os.delivered[900002] = kFollowUpNotificationPayloadPrefix;
    await dueReconciler.onResumed();
    expect(os.delivered.containsKey(900001), isFalse,
        reason: 'the due-date reconciler removes its own stray entry');
    expect(os.delivered.containsKey(900002), isTrue,
        reason: 'and leaves the follow-up entry alone');
    await reconciler.onResumed();
    expect(os.delivered.containsKey(900002), isFalse,
        reason: 'the follow-up reconciler removes its own stray entry');
    expect(os.pending.keys.toSet(), {
      followUpNotificationId('a'),
      dueDateNotificationId('a'),
      dueDateNotificationId('d'),
    });
  });

  test('a follow-up reconciler leaves a due-date tray entry alone', () async {
    os.delivered[900001] = kDueDateNotificationPayloadPrefix;
    await waitingFor('a', followUpFrom: DateTime(2026, 11, 12));
    await settle();

    expect(os.delivered.containsKey(900001), isTrue);
  });
}
