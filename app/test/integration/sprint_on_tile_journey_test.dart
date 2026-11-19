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
///
/// Harness shape follows `day_timeline_journey_test.dart`: the real route over
/// a real database, the databases opened and closed outside the fake-async
/// body, and a bounded number of frames instead of `pumpAndSettle`, which a
/// live drift stream would make spin.
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
import 'package:jeeves/screens/focus_screen.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_projector.dart';
import 'package:jeeves/sync/hlc.dart';
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

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late SyncDatabase sync;
  late Reducer reducer;
  late DomainProjector projector;
  late ProviderContainer container;
  late GoRouter router;

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
    // The sync store is opened outside the test body on purpose: a database
    // opened inside the fake-async body never finishes opening, and the
    // reducer's write would hang.
    sync = SyncDatabase(NativeDatabase.memory());
    final registry = CollectionRegistry(sync);
    reducer = Reducer(
      sync,
      nowMs: () => DateTime.now().millisecondsSinceEpoch,
    );
    projector = DomainProjector(registry: registry, domain: db);
    // The Now screen's own providers are the real ones: the Sprints must reach
    // the tile through the app's own path, not through a test-only override.
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => _now),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    router = GoRouter(
      initialLocation: '/focus',
      routes: [
        GoRoute(path: '/focus', builder: (_, _) => const FocusScreen()),
      ],
    );
  });

  tearDown(() async {
    router.dispose();
    await db.close();
    await sync.close();
  });

  /// Disposing the container cancels the live drift streams, which schedules a
  /// zero-duration timer; it must fire inside the test body.
  Future<void> teardownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => pumpEventQueue());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> openNowScreen(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await _pumpFrames(tester, frames: 20);
  }

  testWidgets('a Sprint recorded here is counted on its tile', (tester) async {
    try {
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

      await openNowScreen(tester);

      expect(find.byKey(const Key('day_timeline')), findsOneWidget);
      expect(find.byKey(const Key('day_timeline_tile_report_1')), findsOneWidget);
      expect(find.textContaining('1 sprint · 23m'), findsOneWidget);
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('a Sprint that arrives by sync is counted on its tile',
      (tester) async {
    try {
      await openNowScreen(tester);
      expect(find.textContaining('1 sprint · 23m'), findsNothing);

      // The peer records a Sprint on the same Action this device has, and its
      // op converges here: the reducer reduces it, the projector writes the
      // row and announces it.
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
    } finally {
      await teardownApp(tester);
    }
  });

  testWidgets('a Sprint that arrives before its Action is counted once the '
      'Action arrives', (tester) async {
    try {
      await openNowScreen(tester);
      expect(find.textContaining('1 sprint · 23m'), findsNothing);

      // The peer recorded a Sprint on an Action this device has not seen yet.
      // The two are separate collections, so either may converge first: the
      // Sprint's op arrives first, and the row lands with an Action that is
      // not here — so it belongs to no Outcome's tile yet.
      await tester.runAsync(() async {
        final affected = await reducer.apply(
          OpPayload(
            collection: sprintsCollection,
            entityId: 'sprint-before-its-action',
            hlc: Hlc(DateTime.now().millisecondsSinceEpoch, 0, _member),
            fields: {
              'user_id': FieldWrite(_userId),
              'action_id': FieldWrite('action-from-a-peer'),
              'started_at': FieldWrite(encodeInstant(_sprintStart)),
              'ended_at': FieldWrite(encodeInstant(_sprintEnd)),
              'planned_duration_minutes': FieldWrite(23),
            },
          ),
          authorMemberIdHex: _member,
        );
        await projector.project(affected);
      });

      await _pumpFrames(tester, frames: 20);

      // The Sprint row is in the store, and it is still on no tile: the Action
      // it ran on has not arrived.
      final rows = (await tester.runAsync(() => db.select(db.sprints).get()))!;
      expect(rows, hasLength(1));
      expect(find.textContaining('1 sprint · 23m'), findsNothing);

      // The Action converges after it. The Sprint now belongs to an Outcome,
      // and the tile shows it — with no further Sprint write.
      await tester.runAsync(() async {
        final affected = await reducer.apply(
          OpPayload(
            collection: actionsCollection,
            entityId: 'action-from-a-peer',
            hlc: Hlc(DateTime.now().millisecondsSinceEpoch, 0, _member),
            fields: {
              'outcome_id': FieldWrite('report'),
              'user_id': FieldWrite(_userId),
              'text': FieldWrite('Draft the report'),
              'role': FieldWrite('done'),
              'created_at': FieldWrite(encodeInstant(_sessionStart)),
            },
          ),
          authorMemberIdHex: _member,
        );
        await projector.project(affected);
      });

      await _pumpFrames(tester, frames: 20);

      expect(find.byKey(const Key('day_timeline_tile_report_1')), findsOneWidget);
      expect(find.textContaining('1 sprint · 23m'), findsOneWidget);
    } finally {
      await teardownApp(tester);
    }
  });
}
