/// Journey: a "Check in" tap on a Habit's notification becomes a Check-in in
/// the database, and the notification for that day goes.
///
/// The tap goes through the production handler and the outbox, and the drain
/// goes through the production drainer. Only the OS plugin (a stand-in for
/// [NotificationService]) and the router are substituted.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'package:jeeves/database/daos/habit_dao.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart';
import 'package:jeeves/models/habit_progress.dart';
import 'package:jeeves/providers/auth_provider.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/habit_check_in_outbox.dart';
import 'package:jeeves/services/habit_notification_response.dart';
import 'package:jeeves/services/habit_notifications.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// The account a signed-in device holds its Habits under.
const _accountId = 'acct-1';

/// A session restore that has not answered yet, and then answers with the
/// account — the production [AuthNotifier]'s shape, with the server left out.
class _PendingRestore extends AuthNotifier {
  _PendingRestore(this._restore);

  final Completer<String?> _restore;

  @override
  Future<String?> build() async {
    // Suspended first, as the production arm is: it writes the user id only
    // after `restore()` has answered, and a write before the first await
    // trips Riverpod's "no modifying other providers while building" assert.
    final token = await _restore.future;
    ref.read(currentUserIdProvider.notifier).setUserId(_accountId);
    return token;
  }
}

void main() {
  setUpAll(() {
    configureSqliteForTests();
    TestWidgetsFlutterBinding.ensureInitialized();
    tz_data.initializeTimeZones();
  });

  late tz.Location kolkata;
  late GtdDatabase db;
  late ProviderContainer container;
  late FakeHabitNotifications os;
  // Friday 20 November 2026, 06:30 local — before the 07:00 a clock-time
  // Habit notifies at.
  var now = DateTime.utc(2026, 11, 20, 1);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    kolkata = tz.getLocation('Asia/Kolkata');
    tz.setLocalLocation(kolkata);
    db = GtdDatabase(NativeDatabase.memory());
    os = FakeHabitNotifications()..deviceZone = 'Asia/Kolkata';
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        notificationServiceProvider.overrideWithValue(os),
        clockProvider.overrideWithValue(() => now),
      ],
    );
    container.read(habitNotificationReconcilerProvider);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> settle() async {
    for (var i = 0; i < 2; i++) {
      await pumpEventQueue();
      await container.read(habitNotificationReconcilerProvider)?.settled();
    }
  }

  Future<String> createHabit({
    required String title,
    HabitCommitmentDraft commitment = defaultNewHabitCommitment,
    String userId = _userId,
  }) async {
    final id = await db.habitDao.createHabit(
      userId: userId,
      title: title,
      today: '2026-11-20',
      now: now,
      firstCommitment: commitment,
    );
    await db.habitDao.setAnchor(
      habitId: id,
      userId: userId,
      today: '2026-11-20',
      now: now,
      kind: HabitAnchorKind.clockTime,
      clockTime: '07:00',
    );
    return id;
  }

  /// The tap on the "Check in" button of [habitId]'s notification.
  Future<void> tapCheckIn(String habitId) async {
    final payload = habitNotificationPayload(
      firstHabitId: habitId,
      clockTimeHabitId: habitId,
      day: '2026-11-20',
      fireAt: tz.TZDateTime(kolkata, 2026, 11, 20, 7),
      action: HabitNotificationAction.checkIn,
      signature: 'abcdef',
    );
    await handleHabitNotificationResponse(
      NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: kNotificationActionHabitCheckIn,
        payload: payload,
      ),
      service: os,
      navigate: (_) {},
      now: () => now,
    );
  }

  Future<int> drain() =>
      drainHabitCheckInOutbox(dao: db.habitDao, userId: _userId);

  Future<List<HabitCheckIn>> checkInsOf(String habitId) async {
    final histories = await db.habitDao.watchHabitHistories().first;
    final history =
        histories.firstWhere((h) => h.habit.id == habitId, orElse: () {
      throw StateError('No Habit $habitId');
    });
    return history.checkIns;
  }

  Future<List<String>> outboxKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs
        .getKeys()
        .where((k) => k.startsWith(kHabitCheckInOutboxKeyPrefix))
        .toList();
  }

  test('a tap becomes one Check-in with that id, day and instant', () async {
    final id = await createHabit(title: 'Stretch');
    await settle();

    await tapCheckIn(id);
    expect(await drain(), 1);

    final checkIns = await checkInsOf(id);
    expect(checkIns, hasLength(1));
    expect(checkIns.single.countsForDay, '2026-11-20');
    expect(checkIns.single.checkedInAt, '2026-11-20T01:00:00.000Z');

    // The streak reads it: today counts as done.
    final histories = await db.habitDao.watchHabitHistories().first;
    final progress = computeHabitProgress(
        histories.firstWhere((h) => h.habit.id == id), DateTime.utc(2026, 11, 20));
    expect(progress.todayState, HabitTodayState.done);
    expect(progress.currentStreak, 1);
  });

  test('draining the same entry twice leaves one Check-in', () async {
    final id = await createHabit(title: 'Stretch');
    await settle();

    await tapCheckIn(id);
    expect(await drain(), 1);
    // The entry is gone, so a second drain has nothing to do.
    expect(await drain(), 0);

    expect(await checkInsOf(id), hasLength(1));
  });

  test('an entry the Habit no longer accepts is dropped', () async {
    final id = await createHabit(title: 'Stretch');
    await settle();

    await tapCheckIn(id);
    // The Habit became measurable: a Check-in now needs an amount.
    await db.habitDao.setCommitment(
      habitId: id,
      userId: _userId,
      today: '2026-11-20',
      now: now,
      commitment: const HabitCommitmentDraft(
        repeatKind: HabitRepeatKind.everyDay,
        unitLabel: 'glasses',
        dailyTargetAmount: 8,
      ),
    );

    expect(await drain(), 0);
    expect(await checkInsOf(id), isEmpty);
    // The outbox is empty, so a bad entry cannot wedge it.
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs
          .getKeys()
          .where((k) => k.startsWith(kHabitCheckInOutboxKeyPrefix))
          .toList(),
      isEmpty,
    );
  });

  test("after the drain, today's notification is cancelled", () async {
    final id = await createHabit(title: 'Stretch');
    await settle();
    expect(os.days, contains('2026-11-20'));

    await tapCheckIn(id);
    await drain();
    await settle();

    expect(os.days, isNot(contains('2026-11-20')));
    expect(os.days, contains('2026-11-21'));
  });

  test('a Check in waits for the session, then is written for the account',
      () async {
    // A Habit of a signed-in account: its row carries the account's id, not
    // the 'local' placeholder the device starts on.
    final id = await createHabit(title: 'Stretch', userId: _accountId);
    await tapCheckIn(id);

    // The drainer is read while the stored session is still being restored —
    // the cold start's order: the app reads its providers, and the account's
    // id only arrives once the restore has answered.
    final restore = Completer<String?>();
    final app = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        authTokenProvider.overrideWith(() => _PendingRestore(restore)),
      ],
    );
    addTearDown(app.dispose);
    app.read(habitCheckInOutboxDrainerProvider);
    await pumpEventQueue();

    // Nothing was written, and nothing was lost: the entry is still out
    // there, waiting for the user it belongs to.
    expect(await checkInsOf(id), isEmpty);
    expect(await outboxKeys(), hasLength(1));

    // The session is restored: the account's id arrives.
    restore.complete('access-token');
    await pumpEventQueue();
    await pumpEventQueue();

    // The Check-in is written, once, for the account.
    final checkIns = await checkInsOf(id);
    expect(checkIns, hasLength(1));
    expect(checkIns.single.countsForDay, '2026-11-20');
    expect(checkIns.single.checkedInAt, '2026-11-20T01:00:00.000Z');
    expect(await outboxKeys(), isEmpty);
  });

  test('a Check in for another user is kept, not dropped', () async {
    // The Habit belongs to the account; the drain runs as the 'local'
    // placeholder, so the write is refused as another user's.
    final id = await createHabit(title: 'Stretch', userId: _accountId);
    await tapCheckIn(id);

    expect(await drain(), 0);
    expect(await checkInsOf(id), isEmpty);
    // The entry waits: a Check-in is not lost to a fault that may pass.
    expect(await outboxKeys(), hasLength(1));

    // The account's id arrives, and the entry is written.
    container.read(currentUserIdProvider.notifier).setUserId(_accountId);
    expect(await drain(), 1);
    expect(await checkInsOf(id), hasLength(1));
    expect(await outboxKeys(), isEmpty);
  });
}
