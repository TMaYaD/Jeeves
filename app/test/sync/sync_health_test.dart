/// `SyncHealth` — the class every sync-state surface reads.
///
/// Two halves: the derivation rules, and the stream a real client produces. What
/// renders it is `_SyncIndicator` in `screens/app_shell.dart`, over
/// `syncStatusProvider`; the standalone `SyncHealthIndicator` widget this file
/// used to exercise was a second, unimported renderer and went with the cutover
/// tooling (#595).
@TestOn('!browser')
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/sync/sync_health.dart';

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
}
