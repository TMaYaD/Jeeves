/// `SyncHealth` — the surface that replaces the PowerSync status indicator.
///
/// Two halves: the stream a real client produces, and the widget that renders
/// it. Both are asserted against the same class, because the contract #551 and
/// #553 inherit is the class, not either consumer.
@TestOn('!browser')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/sync/sync_health.dart';
import 'package:jeeves/widgets/sync_health_indicator.dart';

import 'harness/signal_probe.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const _userId = 'sim-user';

void main() {
  group('the class', () {
    test('clean is derived, never stored', () {
      expect(const SyncHealth().clean, isTrue);
      expect(const SyncHealth(pendingOpCount: 1).clean, isFalse);
      expect(const SyncHealth(unresolvedAlarmCount: 1).clean, isFalse);
      // Quarantine carries the signal until #551's alarms exist, but it is not
      // what `clean` is defined as — that stays pending + unresolved alarms.
      expect(const SyncHealth(quarantineCount: 1).clean, isTrue);
    });
  });

  group('the stream', () {
    late SimWorkspace workspace;
    late SimDevice a;

    setUp(() async {
      workspace = await SimWorkspace.create();
      a = workspace.a;
    });
    tearDown(() async => workspace.close());

    test('queue depth rises while offline and drains on flush', () async {
      expect((await a.client.health()).pendingOpCount, 0);

      a.goOffline();
      await a.domain.todoDao.insertOutcome(
        id: '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f',
        title: 'Ship it',
        userId: _userId,
        now: a.clock.asDateTime,
      );
      final offline = await a.client.health();
      expect(offline.pendingOpCount, 1);
      expect(offline.clean, isFalse);

      a.goOnline();
      final synced = await a.sync();
      expect(synced.pendingOpCount, 0);
      expect(synced.clean, isTrue);
    });

    test('lastSyncedAt stamps on pull completion, not on a drained queue',
        () async {
      // A device with nothing to send still records that it heard from the
      // server: the timestamp must never be a proxy for "healthy".
      final health = await a.sync();
      expect(health.lastSyncedAt, a.clock.asDateTime);
      expect(health.pendingOpCount, 0);
    });

    test('watchSyncHealth re-emits as the outbox changes', () async {
      final seen = <SyncHealth>[];
      final subscription = a.client.watchSyncHealth().listen(seen.add);
      addTearDown(subscription.cancel);
      // The stream is Drift-driven, so every wait here is a condition rather
      // than a duration: a fixed sleep can expire before the re-emission lands
      // and leave the assertion reading the previous value.
      await waitUntil(() => seen.any((health) => health.pendingOpCount == 0));
      expect(seen.last.pendingOpCount, 0);

      a.goOffline();
      await a.domain.todoDao.insertOutcome(
        id: '3f2d1c4e-5a6b-4c8d-9e0f-1a2b3c4d5e6f',
        title: 'Ship it',
        userId: _userId,
        now: a.clock.asDateTime,
      );
      await waitUntil(() => seen.last.pendingOpCount == 1);
      expect(seen.last.pendingOpCount, 1);
    });
  });

  group('the widget', () {
    Future<void> pump(WidgetTester tester, Stream<SyncHealth> stream) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(body: SyncHealthIndicator(stream: stream)),
        ));

    testWidgets('renders the queue depth as a badge', (tester) async {
      await pump(tester, Stream.value(const SyncHealth(pendingOpCount: 3)));
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
    });

    testWidgets('renders the degraded state from !clean', (tester) async {
      await pump(
        tester,
        Stream.value(SyncHealth(
          unresolvedAlarmCount: 2,
          alarmKinds: const {'chain_gap', 'rollback'},
          lastSyncedAt: DateTime.utc(2026, 7, 28, 9),
        )),
      );
      await tester.pump();
      expect(find.byIcon(Icons.gpp_maybe), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('2 integrity alarms'));
      expect(tooltip.message, contains('chain_gap, rollback'));
    });

    testWidgets('a clean, synced device reads as synced', (tester) async {
      await pump(
        tester,
        Stream.value(SyncHealth(lastSyncedAt: DateTime.utc(2026, 7, 28, 9))),
      );
      await tester.pump();
      expect(find.byIcon(Icons.cloud_done), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, startsWith('Synced'));
      expect(tooltip.message, contains('2026-07-28T09:00:00.000Z'));
    });

    testWidgets('quarantined ops surface even while clean', (tester) async {
      await pump(tester, Stream.value(const SyncHealth(quarantineCount: 1)));
      await tester.pump();
      expect(find.byIcon(Icons.gpp_maybe), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, contains('1 refused'));
    });
  });
}
