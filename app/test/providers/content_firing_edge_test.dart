import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/clock_provider.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/nudge_triggers.dart';
import 'package:jeeves/providers/synced_preferences_provider.dart';
import 'package:jeeves/services/notification_service.dart';

import '../helpers/periodic_review_test_helpers.dart';
import '../test_helpers.dart';

// Must match `_contentFiringEdgeKey(RitualId.weeklyReview)` in nudge_triggers.dart.
const _edgeKey = 'periodic_review_nudge_content_firing_edge';

void main() {
  setUpAll(configureSqliteForTests);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('contentFiringEdgeProvider', () {
    late GtdDatabase db;
    late ProviderContainer c;
    var now = DateTime(2026, 6, 29, 9, 0);
    // The Weekly Review content predicate, driven by hand:
    // null = loading, false = loaded-not-firing, true = firing.
    bool? firing;

    // A container over the shared (db, now, firing) seam. `firing` and `now`
    // are read live through the override closures, so mutating them then
    // invalidating re-drives the providers.
    ProviderContainer makeContainer() => ProviderContainer(overrides: [
          databaseProvider.overrideWithValue(db),
          notificationServiceProvider
              .overrideWithValue(StubPeriodicReviewNotificationService()),
          wrContentFiringProvider.overrideWith((ref) => firing),
          clockProvider.overrideWithValue(() => now),
        ]);

    Future<void> setup() async {
      db = GtdDatabase(NativeDatabase.memory());
      now = DateTime(2026, 6, 29, 9, 0);
      firing = null;
      c = makeContainer();
      await c.read(syncedPreferencesProvider.future);
      // Keep the Notifier alive so _prevFiring persists across transitions.
      c.listen(contentFiringEdgeProvider, (_, _) {});
    }

    // Steps the predicate; reading the provider afterwards forces the rebuild
    // so the next transition sees a deterministic previous value.
    void setFiring(bool? value) {
      firing = value;
      c.invalidate(wrContentFiringProvider);
    }

    tearDown(() async {
      c.dispose();
      await db.close();
    });

    test('stamps a fresh edge on a genuine false→true re-fire', () async {
      await setup();

      setFiring(false); // loaded, not firing
      expect(c.read(contentFiringEdgeProvider), isNull); // build, prev=false

      now = DateTime(2026, 6, 29, 14, 30);
      setFiring(true); // false→true re-fire
      expect(c.read(contentFiringEdgeProvider)?.toUtc(),
          DateTime(2026, 6, 29, 14, 30).toUtc());

      // And it was persisted for restart (the write is fire-and-forget — let it
      // settle).
      await Future<void>.delayed(Duration.zero);
      final prefs = c.read(syncedPreferencesProvider).requireValue;
      expect(DateTime.tryParse(prefs.get<String>(_edgeKey) ?? '')?.toUtc(),
          DateTime(2026, 6, 29, 14, 30).toUtc());
    });

    test('keeps the stamped edge on a rebuild while still firing, before the '
        'persist is reflected', () async {
      await setup();

      setFiring(false);
      expect(c.read(contentFiringEdgeProvider), isNull);

      now = DateTime(2026, 6, 29, 14, 30);
      setFiring(true); // false→true: stamps 14:30; the persist is fire-and-forget
      expect(c.read(contentFiringEdgeProvider)?.toUtc(),
          DateTime(2026, 6, 29, 14, 30).toUtc());

      // Rebuild while still firing, synchronously — before the async persist
      // lands in syncedPreferencesProvider (`set` awaits the DB write before
      // updating state, so `persisted` is still null here). The in-memory stamp
      // must hold, so firingSince stays 14:30 rather than regressing to
      // start-of-today (00:00) and re-hiding a just-released dismiss.
      c.invalidate(wrContentFiringProvider); // firing still true
      expect(c.read(contentFiringEdgeProvider)?.toUtc(),
          DateTime(2026, 6, 29, 14, 30).toUtc());
    });

    test('a loading→firing edge on startup uses the start-of-today fallback, '
        'not a fresh stamp', () async {
      await setup();

      // firing starts null (loading) → prev=null.
      expect(c.read(contentFiringEdgeProvider), isNull);

      now = DateTime(2026, 6, 29, 14, 30);
      setFiring(true); // null→true (startup firing)

      // prev==null (not a re-fire) and nothing persisted ⇒ start-of-today, NOT
      // a fresh 14:30 stamp.
      expect(c.read(contentFiringEdgeProvider), DateTime(2026, 6, 29));
    });

    test('restores the persisted edge in a fresh container (restart)', () async {
      await setup();

      // A prior session stamped and persisted an edge.
      final edge = DateTime.utc(2026, 6, 29, 11, 0);
      await c
          .read(syncedPreferencesProvider.notifier)
          .set(_edgeKey, edge.toIso8601String());

      // Simulate a restart: drop the container (keeping the backing DB) and
      // build a fresh one that is already firing on startup. A fresh notifier
      // carries no in-memory stamp, so a correct read can only come from prefs —
      // this proves cold-start restore, not in-memory state reuse.
      c.dispose();
      firing = true;
      c = makeContainer();
      await c.read(syncedPreferencesProvider.future);

      expect(c.read(contentFiringEdgeProvider)?.toUtc(), edge);
    });
  });
}
