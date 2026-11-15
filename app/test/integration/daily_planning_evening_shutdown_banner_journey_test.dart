import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/providers/nudge_clock_provider.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// Which banner the user sees at each moment, for every session state of the
/// accepted Daily Planning / Evening Shutdown table. One test per row, named
/// `row N`. Real database, real providers, only the clock is moved.
///
/// Defaults: Daily Planning 08:00, Evening Shutdown 18:00, 8 h available.
/// Wed 11 Nov 2026 is "today"; Tue 10 Nov is "yesterday".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer c;
  late ProviderSubscription<RitualId?> head;
  late DateTime now;

  DateTime at(int day, int hour, [int minute = 0]) =>
      DateTime(2026, 11, day, hour, minute);

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    now = at(11, 7);
    db = GtdDatabase(NativeDatabase.memory());
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
    ]);
    // One inbox item, created early so Weekly Review is not due in any row.
    await db.captureDao.insertCapture(CapturesCompanion(
      id: const Value('inbox'),
      title: const Value('Review this capture'),
      userId: const Value('local'),
      createdAt: Value(at(10, 7)),
      updatedAt: Value(at(10, 7)),
    ));
    await c.read(syncedPreferencesProvider.future);
    head = c.listen(nudgeQueueHeadProvider, (_, _) {});
  });

  tearDown(() async {
    head.close();
    c.dispose();
    await db.close();
  });

  /// The banner at [when], after the boundary timer has ticked.
  Future<RitualId?> bannerAt(DateTime when) async {
    now = when;
    c.invalidate(nudgeBoundaryTickProvider);
    await settle();
    return head.read();
  }

  Future<String> open(DateTime startedAt) => db.focusSessionDao
      .openSession(userId: 'local', taskIds: const [], now: startedAt);

  Future<void> close(String id, DateTime endedAt) =>
      db.focusSessionDao.closeSession(sessionId: id, now: endedAt);

  Future<void> swipe(RitualId ritual, DateTime when) async {
    now = when;
    await c.read(nudgeActionsProvider).dismiss(ritual, at: when);
  }

  test('row 1: no session, Night: nothing', () async {
    expect(await bannerAt(at(11, 3)), isNull);
  });

  test('row 2: no session, Day: Plan your day', () async {
    expect(await bannerAt(at(11, 9)), RitualId.dailyPlanning);
  });

  test('row 3: no session, Evening: nothing', () async {
    expect(await bannerAt(at(11, 19)), isNull);
  });

  test('row 4: session opened in the Night: nothing until 18:00', () async {
    await open(at(11, 7, 30));
    expect(await bannerAt(at(11, 7, 45)), isNull);
    expect(await bannerAt(at(11, 12)), isNull);
    expect(await bannerAt(at(11, 17, 59)), isNull);
  });

  test('row 5: session opened in the Day: nothing until 18:00', () async {
    await open(at(11, 10));
    expect(await bannerAt(at(11, 12)), isNull);
    expect(await bannerAt(at(11, 17, 59)), isNull);
  });

  test('row 6: open session: Evening Shutdown from its due time', () async {
    await open(at(11, 10));
    expect(await bannerAt(at(11, 18)), RitualId.eveningShutdown);
    expect(await bannerAt(at(11, 21)), RitualId.eveningShutdown);
  });

  test('row 7: closed session: nothing in the period', () async {
    final id = await open(at(11, 9));
    await close(id, at(11, 12));
    expect(await bannerAt(at(11, 13)), isNull);
    expect(await bannerAt(at(11, 19)), isNull);
  });

  test('row 8: Evening Shutdown swiped: nothing for the rest of the Evening',
      () async {
    await open(at(11, 10));
    expect(await bannerAt(at(11, 18, 5)), RitualId.eveningShutdown);
    await swipe(RitualId.eveningShutdown, at(11, 18, 5));
    expect(await bannerAt(at(11, 19, 30)), isNull);
    expect(await bannerAt(at(11, 23, 30)), isNull);
  });

  test('row 9: session left open from an earlier day: Evening Shutdown through the Night',
      () async {
    await open(at(10, 10));
    expect(await bannerAt(at(10, 23, 30)), RitualId.eveningShutdown);
    expect(await bannerAt(at(11, 0, 30)), RitualId.eveningShutdown);
    expect(await bannerAt(at(11, 3)), RitualId.eveningShutdown);
  });

  test('row 10: session left open from an earlier day, Day: Evening Shutdown, not Plan your day',
      () async {
    await open(at(10, 10));
    expect(await bannerAt(at(11, 9)), RitualId.eveningShutdown);
  });

  test('row 11: session left open from an earlier day, Evening: Evening Shutdown', () async {
    await open(at(10, 10));
    expect(await bannerAt(at(11, 19)), RitualId.eveningShutdown);
  });

  test('row 12: session left open from an earlier day, closed in the Day: Plan your day appears',
      () async {
    final id = await open(at(10, 10));
    expect(await bannerAt(at(11, 9)), RitualId.eveningShutdown);
    await close(id, at(11, 9, 30));
    expect(await bannerAt(at(11, 9, 31)), RitualId.dailyPlanning);
  });

  test('row 13: swiped banner for a session left open returns at the next planning and '
      'shutdown times', () async {
    await open(at(10, 10));
    expect(await bannerAt(at(11, 9)), RitualId.eveningShutdown);
    await swipe(RitualId.eveningShutdown, at(11, 9));
    expect(await bannerAt(at(11, 12)), isNull);
    expect(await bannerAt(at(11, 18)), RitualId.eveningShutdown);
    await swipe(RitualId.eveningShutdown, at(11, 18, 5));
    expect(await bannerAt(at(11, 23)), isNull);
    expect(await bannerAt(at(12, 8)), RitualId.eveningShutdown);
  });

  test('row 14: session opened in the Evening: Evening Shutdown only at '
      'start + available time', () async {
    await c.read(syncedPreferencesProvider.notifier)
        .set(kLastSessionAvailableMinutesKey, 180);
    await open(at(11, 20));
    expect(await bannerAt(at(11, 20, 30)), isNull);
    expect(await bannerAt(at(11, 22, 59)), isNull);
    expect(await bannerAt(at(11, 23)), RitualId.eveningShutdown);
  });

  test('row 15: session opened in the Evening and closed: Plan your day next '
      'morning', () async {
    final id = await open(at(11, 20));
    await close(id, at(11, 20, 30));
    expect(await bannerAt(at(12, 8, 5)), RitualId.dailyPlanning);
  });

  test('row 16: Evening session still open next planning time: Evening '
      'Shutdown, then Plan your day once closed', () async {
    final id = await open(at(11, 20));
    expect(await bannerAt(at(12, 8, 5)), RitualId.eveningShutdown);
    await close(id, at(12, 8, 30));
    expect(await bannerAt(at(12, 8, 31)), RitualId.dailyPlanning);
  });

  test('row 17: Plan your day swiped: nothing until the next planning time',
      () async {
    expect(await bannerAt(at(11, 9)), RitualId.dailyPlanning);
    await swipe(RitualId.dailyPlanning, at(11, 9));
    expect(await bannerAt(at(11, 12)), isNull);
    expect(await bannerAt(at(11, 19)), isNull);
    expect(await bannerAt(at(12, 3)), isNull);
    expect(await bannerAt(at(12, 8, 5)), RitualId.dailyPlanning);
  });

  test('row 18: planned late in the Day, shut down late: Plan your day next '
      'morning', () async {
    final id = await open(at(11, 17));
    await close(id, at(11, 23));
    expect(await bannerAt(at(12, 8, 5)), RitualId.dailyPlanning);
  });
}
