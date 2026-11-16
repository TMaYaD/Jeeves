/// The Sprints done show on the day timeline's tiles (issue #1029).
///
/// The real Now screen over a real in-memory database: a Sprint recorded on
/// this device is counted on the tile of the Outcome it ran on, and a Sprint a
/// peer recorded arrives by sync and is counted too — while the screen is
/// open, with no restart.
///
/// The sync half is the real convergence path: the op goes through the real
/// [Reducer] on a real [SyncDatabase], and the real [DomainProjector] writes
/// the row into the domain store and announces it, exactly as the sync host
/// does when a peer's Sprint arrives.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/day_timeline_provider.dart';
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_projector.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/host/merge_state.dart';
import 'package:jeeves/sync/op_payload.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_database.dart';

import '../test_helpers.dart';

const _userId = 'local';

/// A peer's member id: 32 lowercase hex characters, as the HLC demands.
const _member = 'dddddddddddddddddddddddddddddddd';

/// The session opens at 08:00 UTC. Every other instant is measured from it,
/// so the day is the same one whatever the host's time zone is.
final _sessionStart = DateTime.utc(2026, 11, 16, 8, 0);
final _sprintStart = _sessionStart.add(const Duration(minutes: 10));
final _sprintEnd = _sprintStart.add(const Duration(minutes: 23));
final _now = _sprintEnd.add(const Duration(minutes: 5));

/// Drains real async and pumps a bounded number of frames: a live drift
/// stream would make `pumpAndSettle` spin.
Future<void> _pumpFrames(WidgetTester tester, {int frames = 8}) async {
  for (var i = 0; i < frames; i++) {
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _app(GtdDatabase db) {
  final router = GoRouter(
    initialLocation: '/focus',
    routes: [
      GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
    ],
  );
  return ProviderScope(
    overrides: [
      nowTimelineExtrasProvider.overrideWithValue(const NowTimelineExtras()),
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => _now),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    await db.todoDao.insertOutcome(
      id: 'report',
      title: 'Write the report',
      userId: _userId,
      timeEstimate: 60,
    );
    await seedCurrentAction(
      db,
      outcomeId: 'report',
      text: 'Draft the report',
      userId: _userId,
      createdAt: _sessionStart,
    );
    await db.focusSessionDao.openSession(
      userId: _userId,
      taskIds: ['report'],
      now: _sessionStart,
    );
  });

  tearDown(() async => db.close());

  testWidgets('a Sprint recorded here is counted on its tile', (tester) async {
    await tester.runAsync(() async {
      await db.sprintDao.startSprint(
        taskId: 'report',
        userId: _userId,
        plannedDurationMinutes: 23,
        now: _sprintStart,
      );
      await db.sprintDao.endRunningSprint(
        userId: _userId,
        now: _sprintEnd,
      );
    });

    await tester.pumpWidget(_app(db));
    await _pumpFrames(tester, frames: 20);

    expect(find.byKey(const Key('day_timeline')), findsOneWidget);
    expect(find.byKey(const Key('day_timeline_tile_report_1')), findsOneWidget);
    expect(find.textContaining('1 sprint · 23m'), findsOneWidget);
  });

  testWidgets('a Sprint that arrives by sync is counted on its tile',
      (tester) async {
    await tester.pumpWidget(_app(db));
    await _pumpFrames(tester, frames: 20);
    expect(find.textContaining('1 sprint · 23m'), findsNothing);

    // The peer records a Sprint on the same Action this device has, and its op
    // converges here: the reducer reduces it, the projector writes the row.
    final sync = SyncDatabase(NativeDatabase.memory());
    addTearDown(() => sync.close());
    final registry = CollectionRegistry(sync);
    final reducer = Reducer(sync, nowMs: () => DateTime.now().millisecondsSinceEpoch);
    final projector = DomainProjector(registry: registry, domain: db);

    await tester.runAsync(() async {
      final affected = await reducer.apply(
        OpPayload(
          collection: sprintsCollection,
          entityId: 'sprint-from-a-peer',
          hlc: Hlc(DateTime.now().millisecondsSinceEpoch, 0, _member),
          fields: {
            'user_id': FieldWrite(_userId),
            'action_id': FieldWrite('action-report'),
            'started_at': FieldWrite(encodeInstant(_sprintStart)),
            'ended_at': FieldWrite(encodeInstant(_sprintEnd)),
            'planned_duration_minutes': FieldWrite(23),
          },
        ),
        authorMemberIdHex: _member,
      );
      await projector.project(affected);
    });

    // The row is in the store; the screen is still open.
    await _pumpFrames(tester, frames: 20);

    final rows = (await tester.runAsync(() => db.select(db.sprints).get()))!;
    expect(rows, hasLength(1));
    expect(find.textContaining('1 sprint · 23m'), findsOneWidget);
  });
}
