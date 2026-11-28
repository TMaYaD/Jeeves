/// The arrival notification journey (issue #1092), over a real store and the
/// real providers.
///
/// The user switched "Tell me when I arrive" on at the hardware store, where
/// "Buy screws" waits. The foreground app writes the arrival snapshot; the OS
/// then wakes the background path with enter and exit events. Only the
/// notification is stood in for, by a sink that records what the user would
/// see. A tap on the notification opens the place page at that Place.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/daos/habit_dao.dart' show HabitCommitmentDraft;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/habit_commitment.dart'
    show HabitRepeatKind, habitDayKey;
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/arrival_notification_settings.dart';
import 'package:jeeves/providers/arrival_snapshot_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/location_source_provider.dart';
import 'package:jeeves/screens/place_page/place_page_screen.dart';
import 'package:jeeves/services/arrival_notifications.dart';
import 'package:jeeves/services/arrival_snapshot.dart';
import 'package:jeeves/services/geofence_registrar.dart'
    show arrivalGeofenceIdPrefix;
import 'package:jeeves/services/habit_notification_response.dart';
import 'package:jeeves/services/location_source.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/fake_geofence_registrar.dart';
import '../helpers/fake_location_source.dart';
import '../test_helpers.dart';

const _userId = 'local';

/// Records what the user would have been told.
class _RecordingSink implements ArrivalNotificationSink {
  final shown = <({int id, String title, String body, String payload})>[];

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    shown.add((id: id, title: title, body: body, payload: payload));
  }
}

/// A sink that takes a moment to post, so overlapping events can interleave.
class _SlowSink extends _RecordingSink {
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await super.show(id: id, title: title, body: body, payload: payload);
  }
}

/// A sink whose notification cannot be posted.
class _FailingSink implements ArrivalNotificationSink {
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    throw StateError('the phone refused the notification');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late Directory directory;
  late ArrivalFiles files;
  late ProviderContainer container;
  late _RecordingSink sink;

  final start = DateTime.utc(2026, 11, 26, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    directory = Directory.systemTemp.createTempSync('jeeves-arrival-notify');
    files = ArrivalFiles(directory);
    sink = _RecordingSink();
    container = ProviderContainer(overrides: [
      geofenceRegistrarProvider.overrideWithValue(FakeGeofenceRegistrar()),
      locationSourceProvider.overrideWithValue(
          FakeLocationSource()..permissionState = LocationPermission.always),
      databaseProvider.overrideWithValue(db),
      // The foreground writes the snapshot for the day the events arrive on.
      clockProvider.overrideWithValue(() => start.toLocal()),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
      arrivalFilesProvider.overrideWith((ref) async => files),
    ]);
    container.listen(arrivalSnapshotReconcilerProvider, (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await db.close();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<String> createPlace(String name, double latitude) async =>
      (await db.placeDao.createNamedPlace(
        name: name,
        latitudeDegrees: latitude,
        longitudeDegrees: 4.8952,
        radiusMeters: 150,
        userId: _userId,
      ))!;

  Future<void> createOutcomeAt(String id, String title, String placeId) async {
    final now = DateTime.now();
    await db.into(db.todos).insert(TodosCompanion(
          id: Value(id),
          title: Value(title),
          intent: const Value('next'),
          userId: const Value(_userId),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
    await seedCurrentAction(db, outcomeId: id, text: 'do $title', userId: _userId);
    final actionId = (await db.actionDao.getCurrentAction(id))!.id;
    await db.actionDao.setNamedPlace(actionId, placeId);
  }

  Future<void> waitForSnapshot(bool Function(ArrivalSnapshot) done) async {
    for (var i = 0; i < 800; i++) {
      if (done(await files.readSnapshot())) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('the arrival snapshot never held what the test waited for');
  }

  Future<void> event(String placeId, {required bool enter, required int atMinute}) =>
      handleArrivalEvent(
        geofenceId: '$arrivalGeofenceIdPrefix$placeId',
        isEnter: enter,
        nowUtc: start.add(Duration(minutes: atMinute)),
        files: files,
        sink: sink,
      );

  Future<String> switchedOnStore() async {
    final storeId = await createPlace('Hardware store', 52.3702);
    await createOutcomeAt('o-screws', 'Buy screws', storeId);
    await container.read(arrivalPlaceIdsProvider.notifier).turnOn(storeId);
    await waitForSnapshot((s) => s.places.any((p) => p.dueCount == 1));
    return storeId;
  }

  test('arriving tells the user once per visit', () async {
    final storeId = await switchedOnStore();

    await event(storeId, enter: true, atMinute: 0);
    expect(sink.shown, hasLength(1));
    expect(sink.shown.single.title, 'Hardware store');
    expect(sink.shown.single.body, contains('Buy screws'));
    expect(sink.shown.single.payload, 'arrival:$storeId');

    // Out, and back within half an hour: the same visit, so no second one.
    await event(storeId, enter: false, atMinute: 5);
    await event(storeId, enter: true, atMinute: 15);
    expect(sink.shown, hasLength(1));

    // Out for 31 minutes: a new visit.
    await event(storeId, enter: false, atMinute: 20);
    await event(storeId, enter: true, atMinute: 51);
    expect(sink.shown, hasLength(2));
  });

  test('two enters that overlap tell the user once', () async {
    final storeId = await switchedOnStore();
    final slow = _SlowSink();
    Future<void> enter() => handleArrivalEvent(
          geofenceId: '$arrivalGeofenceIdPrefix$storeId',
          isEnter: true,
          nowUtc: start,
          files: files,
          sink: slow,
        );
    await Future.wait([enter(), enter()]);
    expect(slow.shown, hasLength(1));
  });

  test('a notification that could not be posted is tried again', () async {
    final storeId = await switchedOnStore();

    await expectLater(
      handleArrivalEvent(
        geofenceId: '$arrivalGeofenceIdPrefix$storeId',
        isEnter: true,
        nowUtc: start,
        files: files,
        sink: _FailingSink(),
      ),
      throwsStateError,
    );

    // The user was not told, so the next arrival event tells them.
    await event(storeId, enter: true, atMinute: 1);
    expect(sink.shown, hasLength(1));
  });

  test('a failed notification leaves the earlier visit not yet announced',
      () async {
    final storeId = await switchedOnStore();
    await event(storeId, enter: true, atMinute: 0);
    await event(storeId, enter: false, atMinute: 5);

    // A new visit, whose notification cannot be posted.
    await expectLater(
      handleArrivalEvent(
        geofenceId: '$arrivalGeofenceIdPrefix$storeId',
        isEnter: true,
        nowUtc: start.add(const Duration(minutes: 60)),
        files: files,
        sink: _FailingSink(),
      ),
      throwsStateError,
    );

    final visit = (await files.readVisits())[storeId]!;
    expect(visit.inside, isFalse);
    expect(visit.notifiedThisVisit, isFalse);
    expect(visit.lastExitAtUtc, start.add(const Duration(minutes: 5)));
  });

  test('the notification id fits the plugin\'s signed 32-bit range', () {
    for (var i = 0; i < 2000; i++) {
      final id = arrivalNotificationId('place-$i');
      expect(id, inInclusiveRange(-0x80000000, 0x7fffffff));
    }
  });

  test('two changes made before the record loads both survive', () async {
    SharedPreferences.setMockInitialValues({
      arrivalNotificationPlaceIdsKey: ['a'],
    });
    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    final notifier = fresh.read(arrivalPlaceIdsProvider.notifier);
    final turnedOn = notifier.turnOn('b');
    final forgotten = notifier.forget('a');
    await Future.wait([turnedOn, forgotten]);
    expect(await fresh.read(arrivalPlaceIdsProvider.future), {'b'});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(arrivalNotificationPlaceIdsKey), ['b']);
  });

  test('a Place switched off says nothing', () async {
    final storeId = await switchedOnStore();
    await container.read(arrivalPlaceIdsProvider.notifier).turnOff(storeId);
    await waitForSnapshot((s) => s.places.isEmpty);

    await event(storeId, enter: true, atMinute: 0);
    expect(sink.shown, isEmpty);
  });

  test('nothing due says nothing', () async {
    final storeId = await switchedOnStore();
    await db.todoDao.markDone('o-screws');
    await waitForSnapshot((s) => s.places.every((p) => p.dueCount == 0));

    await event(storeId, enter: false, atMinute: 0);
    await event(storeId, enter: true, atMinute: 31);
    expect(sink.shown, isEmpty);
  });

  group('Habits due at the Place', () {
    final todayKey = habitDayKey(start.toLocal());

    Future<String> createHabitAt(
      String title,
      String placeId, {
      HabitCommitmentDraft commitment =
          const HabitCommitmentDraft(repeatKind: HabitRepeatKind.everyDay),
    }) async {
      final habitId = await db.habitDao.createHabit(
        userId: _userId,
        title: title,
        today: todayKey,
        now: start,
        firstCommitment: commitment,
      );
      await db.habitDao.setNamedPlace(habitId, placeId, now: start);
      return habitId;
    }

    Future<String> switchedOnGym() async {
      final gymId = await createPlace('Gym', 52.3702);
      return gymId;
    }

    test('the notification names the Habit with the Outcomes due', () async {
      final storeId = await createPlace('Hardware store', 52.3702);
      await createOutcomeAt('o-screws', 'Buy screws', storeId);
      await createHabitAt('Workout', storeId);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(storeId);
      await waitForSnapshot((s) =>
          s.places.any((p) => p.dueCount == 1 && p.dueHabits.isNotEmpty));

      await event(storeId, enter: true, atMinute: 0);

      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.body, contains('One Habit and one Outcome await'));
      expect(sink.shown.single.body, contains('Workout, Buy screws'));
    });

    test('a Habit alone is enough, and the visit rule is unchanged', () async {
      final gymId = await switchedOnGym();
      await createHabitAt('Workout', gymId);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(gymId);
      await waitForSnapshot((s) => s.places.any((p) => p.dueHabits.isNotEmpty));

      await event(gymId, enter: true, atMinute: 0);
      expect(sink.shown, hasLength(1));
      expect(sink.shown.single.title, 'Gym');
      expect(sink.shown.single.body, contains('One Habit awaits'));
      expect(sink.shown.single.body, endsWith('Workout.'));

      // The same visit: out, and back within half an hour.
      await event(gymId, enter: false, atMinute: 5);
      await event(gymId, enter: true, atMinute: 15);
      expect(sink.shown, hasLength(1));
    });

    test('a Habit that is not for today says nothing', () async {
      final gymId = await switchedOnGym();
      // Chosen weekdays, none of them the day the user arrives on.
      final otherWeekday = start.toLocal().weekday % 7 + 1;
      await createHabitAt(
        'Swim',
        gymId,
        commitment: HabitCommitmentDraft(
          repeatKind: HabitRepeatKind.chosenWeekdays,
          chosenWeekdays: [otherWeekday],
        ),
      );
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(gymId);
      await waitForSnapshot((s) => s.places.any((p) => p.dueHabits.isNotEmpty));

      await event(gymId, enter: true, atMinute: 0);
      expect(sink.shown, isEmpty);
    });

    test('a Habit checked in today says nothing', () async {
      final gymId = await switchedOnGym();
      final habitId = await createHabitAt('Workout', gymId);
      await container.read(arrivalPlaceIdsProvider.notifier).turnOn(gymId);
      await waitForSnapshot((s) => s.places.any(
          (p) => p.dueHabits.any((h) => h.forDayKeys.contains(todayKey))));

      await db.habitDao.addCheckIn(
        habitId: habitId,
        userId: _userId,
        countsForDay: todayKey,
        now: start,
      );
      await waitForSnapshot((s) => s.places.any(
          (p) => p.dueHabits.every((h) => !h.forDayKeys.contains(todayKey))));

      await event(gymId, enter: true, atMinute: 0);
      expect(sink.shown, isEmpty);
    });
  });

  testWidgets('tapping the notification opens the place page at that Place',
      (tester) async {
    // The store, the files and the wait for the snapshot are real time, which
    // the widget test's clock does not advance by itself.
    final payload = (await tester.runAsync(() async {
      final alphaId = await createPlace('Alpha', 52.30);
      await createOutcomeAt('o-alpha', 'Water the plants', alphaId);
      final storeId = await switchedOnStore();
      await event(storeId, enter: true, atMinute: 0);
      return sink.shown.single.payload;
    }))!;

    final router = GoRouter(
      initialLocation: '/places',
      routes: [
        GoRoute(path: '/places', builder: PlacePageScreen.buildRoute),
      ],
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    try {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump(const Duration(milliseconds: 150));
      }

      await handleNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: payload,
        ),
        service: StubNotificationService(),
        navigate: router.go,
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => pumpEventQueue());
        await tester.pump(const Duration(milliseconds: 150));
      }

      final list = tester.getRect(find.byType(CustomScrollView));
      final header = find.text('Hardware store');
      expect(header, findsOneWidget);
      expect(tester.getRect(header).top - list.top, lessThan(50));
      expect(find.text('Alpha').evaluate().isEmpty ||
          !tester.getRect(find.text('Alpha')).overlaps(list), isTrue);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
