/// Bypassed Outcomes (CONTEXT.md § Engagement, Bypassed): the threshold
/// setting, the Outcomes the Weekly Review's Bypassed step decides, and the two
/// decisions the user can take on each.
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/focus_session_dao.dart' show BypassedOutcome;
import '../database/gtd_database.dart';
import '../models/bypassed_outcome.dart';
import '../models/todo.dart' show RoutingKind;
import '../services/clarification_service.dart';
import '../sync/collection_codecs.dart'
    show encodeInstant, outcomeBypassDecisionsCollection;
import '../utils/uuid.dart';
import 'auth_provider.dart';
import 'database_provider.dart';
import 'synced_preferences_provider.dart';

/// How many FocusSessions must have passed an Outcome over before it is Bypassed.
/// Synced under `bypass_threshold`; defaults to
/// [kDefaultBypassThreshold].
final bypassThresholdProvider =
    NotifierProvider<BypassThresholdNotifier, int>(
  BypassThresholdNotifier.new,
);

class BypassThresholdNotifier extends Notifier<int> {
  @override
  int build() {
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) state = _fromPrefs(next.value);
    });
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    return current == null ? kDefaultBypassThreshold : _fromPrefs(current);
  }

  int _fromPrefs(SyncedPreferences prefs) {
    final stored = prefs.get<int>(kBypassThresholdPrefKey);
    return (stored == null || stored < 1) ? kDefaultBypassThreshold : stored;
  }

  Future<void> set(int threshold) =>
      syncedPrefs(ref).set(kBypassThresholdPrefKey, threshold);
}

/// The Bypassed Outcomes right now, read once. The Weekly Review step does not
/// watch it: a decided Outcome leaves the step's snapshot, never the live list.
final bypassedOutcomesProvider = FutureProvider.autoDispose<List<BypassedOutcome>>((ref) {
  final db = ref.watch(databaseProvider);
  final threshold = ref.watch(bypassThresholdProvider);
  return db.focusSessionDao.getBypassedOutcomes(threshold);
});

/// How many Outcomes are Bypassed, live — for System Trust.
final bypassedOutcomeCountProvider = StreamProvider<int>((ref) {
  final db = ref.watch(databaseProvider);
  final threshold = ref.watch(bypassThresholdProvider);
  return db.focusSessionDao
      .watchBypassedOutcomes(threshold)
      .map((bypassed) => bypassed.length);
});

/// The Bypassed decision log (Outcome, choice, time), newest first.
final bypassDecisionsProvider =
    StreamProvider<List<OutcomeBypassDecision>>((ref) {
  return ref.watch(databaseProvider).focusSessionDao.watchBypassDecisions();
});

final bypassActionsProvider = Provider<BypassActions>(
  (ref) => BypassActions(ref),
);

/// The two Bypassed decisions. Each routes the Outcome through
/// [ClarificationService.clarifyToOutcome] and logs the decision in one
/// capturing scope, so a routing without its log row (or the reverse) cannot
/// be committed.
class BypassActions {
  BypassActions(this._ref);

  final Ref _ref;

  /// Both decisions return whether the routing landed. `false` means the
  /// Outcome no longer exists, so nothing was routed or logged and the caller
  /// must not credit a decision.
  Future<bool> moveToSomedayMaybe(String outcomeId) =>
      _decide(outcomeId, BypassDecision.maybe, RoutingKind.maybe);

  Future<bool> trash(String outcomeId) =>
      _decide(outcomeId, BypassDecision.trash, RoutingKind.trash);

  Future<bool> _decide(
    String outcomeId,
    BypassDecision decision,
    RoutingKind routing,
  ) async {
    final db = _ref.read(databaseProvider);
    final userId = _ref.read(currentUserIdProvider);
    final decidedAt = DateTime.now().toUtc();
    var landed = false;
    await db.capturing(() async {
      final routed = await _ref
          .read(clarificationServiceProvider)
          .clarifyToOutcome(outcomeId, to: routing, userId: userId);
      // A vanished Outcome has nothing to log.
      if (!routed) return;
      final decisionId = uuid.v4();
      await db.into(db.outcomeBypassDecisions).insert(
            OutcomeBypassDecisionsCompanion(
              id: Value(decisionId),
              taskId: Value(outcomeId),
              decision: Value(decision.name),
              decidedAt: Value(decidedAt),
              userId: Value(userId),
            ),
          );
      db.opCapture.write(
        collection: outcomeBypassDecisionsCollection,
        entityId: decisionId,
        fields: {
          'task_id': outcomeId,
          'decision': decision.name,
          'decided_at': encodeInstant(decidedAt),
          'user_id': userId,
        },
      );
      db.notifyFocusSessionsViewWrite();
      landed = true;
    });
    _ref.invalidate(bypassedOutcomesProvider);
    return landed;
  }
}
