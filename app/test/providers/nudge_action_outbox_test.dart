import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_action_outbox.dart';
import 'package:jeeves/providers/nudge_provider.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers.dart';

/// Drains or migrates through a provider so the functions get a real [Ref].
final _drainProvider = FutureProvider<int>(
    (ref) => drainNudgeActionOutbox(ref));
final _migrateProvider = FutureProvider<void>(
    (ref) => migrateLegacyNotificationSuppression(ref));

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer c;
  final now = DateTime(2026, 11, 11, 10);
  const today = '2026-11-11';

  Future<void> boot([Map<String, Object> prefs = const {}]) async {
    SharedPreferences.setMockInitialValues(prefs);
    db = GtdDatabase(NativeDatabase.memory());
    c = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      clockProvider.overrideWithValue(() => now),
    ]);
    await c.read(syncedPreferencesProvider.future);
  }

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  Future<List<String>> outbox() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return (prefs
            .getKeys()
            .where((k) => k.startsWith(kNudgeActionOutboxKeyPrefix))
            .toList()
          ..sort())
        .map((k) => prefs.getString(k)!)
        .toList();
  }

  group('outbox', () {
    test('records skip as a dismiss and snooze with its expiry, in order',
        () async {
      await boot();
      final tapped = now.subtract(const Duration(minutes: 5));
      await recordRitualNotificationAction(
        ritual: RitualId.dailyPlanning,
        kind: RitualNotificationActionKind.skip,
        at: tapped,
        snoozeMinutes: 60,
      );
      await recordRitualNotificationAction(
        ritual: RitualId.weeklyReview,
        kind: RitualNotificationActionKind.snooze,
        at: tapped.add(const Duration(seconds: 1)),
        snoozeMinutes: 45,
      );
      await recordRitualNotificationAction(
        ritual: RitualId.weeklyReview,
        kind: RitualNotificationActionKind.open,
        at: tapped,
        snoozeMinutes: 60,
      );

      final entries =
          (await outbox()).map(PendingNudgeAction.tryParse).toList();
      expect(entries, hasLength(2), reason: 'open is routing, not recorded');
      expect(entries[0]!.ritual, RitualId.dailyPlanning);
      expect(entries[0]!.verb, NudgeActionVerb.dismiss);
      expect(entries[0]!.at.isAtSameMomentAs(tapped), isTrue);
      expect(entries[1]!.verb, NudgeActionVerb.snooze);
      expect(
          entries[1]!
              .until!
              .isAtSameMomentAs(tapped
                  .add(const Duration(seconds: 1, minutes: 45))),
          isTrue);
    });

    test('a corrupt entry is skipped and still cleared', () async {
      await boot({
        '${kNudgeActionOutboxKeyPrefix}0': 'not json',
      });
      expect(await c.read(_drainProvider.future), 0);
      expect(await outbox(), isEmpty);
    });

    test('drain applies the action time, not the drain time, and clears',
        () async {
      await boot();
      final tapped = now.subtract(const Duration(hours: 3));
      await recordRitualNotificationAction(
        ritual: RitualId.eveningShutdown,
        kind: RitualNotificationActionKind.skip,
        at: tapped,
        snoozeMinutes: 60,
      );

      expect(await c.read(_drainProvider.future), 1);

      final state = c.read(nudgeStateProvider(RitualId.eveningShutdown));
      expect(state.dismissedAt!.isAtSameMomentAs(tapped), isTrue);
      expect(await outbox(), isEmpty);
    });

    test('drain applies a snooze expiry', () async {
      await boot();
      await recordRitualNotificationAction(
        ritual: RitualId.weeklyReview,
        kind: RitualNotificationActionKind.snooze,
        at: now,
        snoozeMinutes: 60,
      );

      await c.read(_drainProvider.future);

      final state = c.read(nudgeStateProvider(RitualId.weeklyReview));
      expect(state.snoozedUntil!
          .isAtSameMomentAs(now.add(const Duration(minutes: 60))), isTrue);
    });

    test('an older dismissal never overwrites a later one', () async {
      await boot();
      final later = now.subtract(const Duration(minutes: 1));
      await c
          .read(nudgeActionsProvider)
          .dismiss(RitualId.dailyPlanning, at: later);
      await recordRitualNotificationAction(
        ritual: RitualId.dailyPlanning,
        kind: RitualNotificationActionKind.skip,
        at: now.subtract(const Duration(hours: 1)),
        snoozeMinutes: 60,
      );

      await c.read(_drainProvider.future);

      expect(
          c
              .read(nudgeStateProvider(RitualId.dailyPlanning))
              .dismissedAt!
              .isAtSameMomentAs(later),
          isTrue);
    });
  });

  group('outbox concurrency', () {
    test('simultaneous appends all survive', () async {
      await boot();
      await Future.wait([
        for (var i = 0; i < 20; i++)
          recordRitualNotificationAction(
            ritual: RitualId.weeklyReview,
            kind: RitualNotificationActionKind.skip,
            at: now, // identical tap time: keys must still not collide
            snoozeMinutes: 60,
          ),
      ]);
      expect(await outbox(), hasLength(20));
    });

    test('an action appended while a drain runs is never lost', () async {
      await boot();
      await recordRitualNotificationAction(
        ritual: RitualId.dailyPlanning,
        kind: RitualNotificationActionKind.skip,
        at: now.subtract(const Duration(minutes: 10)),
        snoozeMinutes: 60,
      );
      final draining = c.read(_drainProvider.future);
      await recordRitualNotificationAction(
        ritual: RitualId.eveningShutdown,
        kind: RitualNotificationActionKind.skip,
        at: now.subtract(const Duration(minutes: 5)),
        snoozeMinutes: 60,
      );
      final firstApplied = await draining;
      c.invalidate(_drainProvider);
      final secondApplied = await c.read(_drainProvider.future);

      expect(firstApplied + secondApplied, 2);
      expect(c.read(nudgeStateProvider(RitualId.eveningShutdown)).dismissedAt,
          isNotNull);
      expect(await outbox(), isEmpty);
    });

    test('a delayed older snooze never shortens a later one', () async {
      await boot();
      // Tapped 09:00 -> expires 10:00; drained after an 11:00 snooze exists.
      final laterExpiry = now.add(const Duration(hours: 1));
      await c.read(nudgeActionsProvider).snooze(
          RitualId.weeklyReview, const Duration(hours: 2),
          at: now.subtract(const Duration(hours: 1)));
      await recordRitualNotificationAction(
        ritual: RitualId.weeklyReview,
        kind: RitualNotificationActionKind.snooze,
        at: now.subtract(const Duration(hours: 1)),
        snoozeMinutes: 60,
      );

      await c.read(_drainProvider.future);

      expect(
          c
              .read(nudgeStateProvider(RitualId.weeklyReview))
              .snoozedUntil!
              .isAtSameMomentAs(laterExpiry),
          isTrue);
      expect(await outbox(), isEmpty);
    });
  });

  group('legacy migration', () {
    test("today's skip becomes a dismiss at now; legacy keys stay", () async {
      await boot({'planning_notification_skipped_date': today});
      await c.read(_migrateProvider.future);

      expect(
          c
              .read(nudgeStateProvider(RitualId.dailyPlanning))
              .dismissedAt!
              .isAtSameMomentAs(now),
          isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('planning_notification_skipped_date'), today);
      expect(prefs.getBool(kNudgeLegacyMigrationMarkerKey), isTrue);
    });

    test('a skip recorded in the synced snapshot is carried too', () async {
      await boot();
      await c
          .read(syncedPreferencesProvider.notifier)
          .set('shutdown_notification_skipped_date', today);
      await c.read(_migrateProvider.future);

      expect(c.read(nudgeStateProvider(RitualId.eveningShutdown)).dismissedAt,
          isNotNull);
    });

    test('a stale skip and an expired snooze are ignored', () async {
      await boot({
        'planning_notification_skipped_date': '2026-11-10',
        'periodic_review_notification_snoozed_until':
            now.subtract(const Duration(minutes: 1)).toIso8601String(),
      });
      await c.read(_migrateProvider.future);

      expect(c.read(nudgeStateProvider(RitualId.dailyPlanning)),
          const NudgeState());
      expect(c.read(nudgeStateProvider(RitualId.weeklyReview)),
          const NudgeState());
    });

    test('a live snooze is carried as the max of existing and legacy',
        () async {
      final legacy = now.add(const Duration(minutes: 30));
      await boot({
        'planning_notification_snoozed_until': legacy.toIso8601String(),
        'shutdown_notification_snoozed_until': legacy.toIso8601String(),
      });
      // Shutdown already has a longer snooze; planning has none.
      final longer = now.add(const Duration(hours: 3));
      await c.read(nudgeActionsProvider).snooze(
          RitualId.eveningShutdown, longer.difference(now),
          at: now);

      await c.read(_migrateProvider.future);

      expect(
          c
              .read(nudgeStateProvider(RitualId.dailyPlanning))
              .snoozedUntil!
              .isAtSameMomentAs(legacy),
          isTrue);
      expect(
          c
              .read(nudgeStateProvider(RitualId.eveningShutdown))
              .snoozedUntil!
              .isAtSameMomentAs(longer),
          isTrue);
    });

    test('a second run is a no-op', () async {
      await boot({'planning_notification_skipped_date': today});
      await c.read(_migrateProvider.future);
      final afterFirst = c.read(nudgeStateProvider(RitualId.dailyPlanning));

      // The user acts again later; a re-run must not clobber it.
      final laterDismissal = now.add(const Duration(hours: 1));
      await c
          .read(nudgeActionsProvider)
          .dismiss(RitualId.dailyPlanning, at: laterDismissal);
      c.invalidate(_migrateProvider);
      await c.read(_migrateProvider.future);

      expect(afterFirst.dismissedAt, isNotNull);
      expect(
          c
              .read(nudgeStateProvider(RitualId.dailyPlanning))
              .dismissedAt!
              .isAtSameMomentAs(laterDismissal),
          isTrue);
    });
  });
}
