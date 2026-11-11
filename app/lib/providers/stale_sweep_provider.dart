/// The Stale sweep (CONTEXT.md § Engagement, Stale): the threshold setting, the
/// Stale Outcomes Daily Planning shows before its wizard, and the two decisions
/// the user can take on each.
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/focus_session_dao.dart' show StaleOutcome;
import '../database/gtd_database.dart';
import '../models/stale_sweep.dart';
import '../models/todo.dart' show RoutingKind;
import '../services/clarification_service.dart';
import '../sync/collection_codecs.dart'
    show encodeInstant, outcomeSweepDecisionsCollection;
import '../utils/uuid.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'focus_session_planning_provider.dart';
import 'synced_preferences_provider.dart';

/// How many FocusSessions must have passed an Outcome over before it is Stale.
/// Synced under `stale_sweep_threshold`; defaults to
/// [kDefaultStaleSweepThreshold].
final staleSweepThresholdProvider =
    NotifierProvider<StaleSweepThresholdNotifier, int>(
  StaleSweepThresholdNotifier.new,
);

class StaleSweepThresholdNotifier extends Notifier<int> {
  @override
  int build() {
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) state = _fromPrefs(next.value);
    });
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    return current == null ? kDefaultStaleSweepThreshold : _fromPrefs(current);
  }

  int _fromPrefs(SyncedPreferences prefs) {
    final stored = prefs.get<int>(kStaleSweepThresholdPrefKey);
    return (stored == null || stored < 1) ? kDefaultStaleSweepThreshold : stored;
  }

  Future<void> set(int threshold) =>
      syncedPrefs(ref).set(kStaleSweepThresholdPrefKey, threshold);
}

/// The Stale Outcomes right now, read once. Daily Planning gates on this; the
/// sweep notifier invalidates it after each decision so the list shrinks.
/// A one-shot read, not a watch: Planning runs with no session open, so the
/// counts cannot change underneath it.
final staleOutcomesProvider = FutureProvider.autoDispose<List<StaleOutcome>>((ref) {
  final db = ref.watch(databaseProvider);
  final threshold = ref.watch(staleSweepThresholdProvider);
  return db.focusSessionDao.getStaleOutcomes(threshold);
});

/// How many Outcomes are Stale, live — for system health.
final staleOutcomeCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final threshold = ref.watch(staleSweepThresholdProvider);
  return db.focusSessionDao
      .watchStaleOutcomes(threshold)
      .map((stale) => stale.length);
});

/// The sweep's decision log (Outcome, choice, time), newest first.
final staleSweepDecisionsProvider =
    StreamProvider<List<OutcomeSweepDecision>>((ref) {
  return ref.watch(databaseProvider).focusSessionDao.watchSweepDecisions();
});

final staleSweepProvider = Provider<StaleSweepActions>(
  (ref) => StaleSweepActions(ref),
);

/// The two sweep decisions. Each routes the Outcome through
/// [ClarificationService.clarifyToOutcome] and logs the decision in one
/// capturing scope, so a routing without its log row (or the reverse) cannot
/// be committed.
class StaleSweepActions {
  StaleSweepActions(this._ref);

  final Ref _ref;

  Future<void> moveToSomedayMaybe(String outcomeId) =>
      _decide(outcomeId, StaleSweepDecision.maybe, RoutingKind.maybe);

  Future<void> trash(String outcomeId) =>
      _decide(outcomeId, StaleSweepDecision.trash, RoutingKind.trash);

  Future<void> _decide(
    String outcomeId,
    StaleSweepDecision decision,
    RoutingKind routing,
  ) async {
    final db = _ref.read(databaseProvider);
    final userId = _ref.read(currentUserIdProvider);
    final decidedAt = DateTime.now().toUtc();
    await db.capturing(() async {
      final routed = await _ref
          .read(clarificationServiceProvider)
          .clarifyToOutcome(outcomeId, to: routing, userId: userId);
      // A vanished Outcome has nothing to log.
      if (!routed) return;
      final decisionId = uuid.v4();
      await db.into(db.outcomeSweepDecisions).insert(
            OutcomeSweepDecisionsCompanion(
              id: Value(decisionId),
              taskId: Value(outcomeId),
              decision: Value(decision.name),
              decidedAt: Value(decidedAt),
              userId: Value(userId),
            ),
          );
      db.opCapture.write(
        collection: outcomeSweepDecisionsCollection,
        entityId: decisionId,
        fields: {
          'task_id': outcomeId,
          'decision': decision.name,
          'decided_at': encodeInstant(decidedAt),
          'user_id': userId,
        },
      );
      db.notifyFocusSessionsViewWrite();
    });
    // The draft Plan must not keep (or later regain) the swept Outcome.
    _ref
        .read(focusSessionPlanningProvider.notifier)
        .forgetSweptOutcome(outcomeId);
    _ref.invalidate(staleOutcomesProvider);
  }
}
