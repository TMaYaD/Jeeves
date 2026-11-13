import 'package:drift/drift.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/services/notification_service.dart';

/// Call once before any test that uses [NativeDatabase].
///
/// sqlite3 >=3.0 loads the native library via build hooks rather than
/// runtime [DynamicLibrary] overrides, so no manual path fixup is needed.
void configureSqliteForTests() {}

/// Seeds the `current` Action row carrying [text] for [outcomeId] — the only
/// grain the app reads or writes for "what is this Outcome's next move?"
/// (ADR-0001 story 3).
///
/// Any fixture that wants an Outcome to *have* a next action must call this.
/// There is no Outcome column to set instead — the `todos.next_action_text`
/// cursor was retired and then dropped. A blank or null
/// [text] seeds nothing, mirroring the blank → Actionless normalisation
/// `setCurrentActionText` applies.
///
/// [id] defaults to `action-<outcomeId>`; pass it when a test needs a second
/// row on the same Outcome or a specific winner-rule ordering.
Future<void> seedCurrentAction(
  GtdDatabase db, {
  required String outcomeId,
  required String? text,
  required String userId,
  String? id,
  DateTime? createdAt,
}) async {
  final normalized = text?.trim() ?? '';
  if (normalized.isEmpty) return;
  await db.into(db.actions).insert(ActionsCompanion(
        id: Value(id ?? 'action-$outcomeId'),
        outcomeId: Value(outcomeId),
        userId: Value(userId),
        actionText: Value(normalized),
        role: const Value('current'),
        createdAt: Value(createdAt ?? DateTime.now()),
      ));
}

/// Seeds a `planned` Action row for [outcomeId] — one entry of the Outcome's
/// planned queue (ADR-0004 story 5).
///
/// Unlike a call to `ActionDao.addPlannedAction`, this bypasses the stamping
/// primitive so a fixture can control `created_at`/`updated_at` — pass an
/// explicit earlier [now] to prove that a later promotion moves
/// `last_clarified_at` strictly forward rather than merely leaving it non-null.
/// [id] and [position] let a fixture seed a deterministic queue order.
Future<void> seedPlannedAction(
  GtdDatabase db, {
  required String outcomeId,
  required String text,
  required String userId,
  required String id,
  required int position,
  String? energyLevel,
  int? timeEstimate,
  DateTime? now,
}) async {
  final ts = now ?? DateTime.now();
  await db.into(db.actions).insert(ActionsCompanion(
        id: Value(id),
        outcomeId: Value(outcomeId),
        userId: Value(userId),
        actionText: Value(text),
        role: const Value('planned'),
        position: Value(position),
        energyLevel: Value(energyLevel),
        timeEstimate: Value(timeEstimate),
        createdAt: Value(ts),
        updatedAt: Value(ts),
      ));
}

/// Stands in for the OS notification plugin: records what the Nudge
/// notification scheduler and the notification action handler ask of it, and
/// answers the "what is pending / delivered" queries from that record. Unit,
/// widget and journey tests wire it in via
/// `notificationServiceProvider.overrideWithValue(...)` so they never touch a
/// real plugin.
class RecordingNotificationService extends NotificationService {
  RecordingNotificationService() : super.forTesting();

  /// Alarms the OS would hold, by notification id.
  final pending = <int, RecordedRitualAlarm>{};

  /// Ritual notifications sitting in the tray.
  final delivered = <({int id, RitualId ritual})>[];

  /// Every id passed to [cancelReminder], in order.
  final cancelledIds = <int>[];

  /// Every schedule call, in order, for tests asserting on churn.
  final scheduleCalls = <int>[];

  @override
  Future<void> scheduleRitualNotification({
    required int id,
    required RitualId ritual,
    required DateTime fireAt,
    required String payload,
  }) async {
    scheduleCalls.add(id);
    pending[id] = RecordedRitualAlarm(ritual, fireAt, payload, false);
  }

  @override
  Future<void> scheduleRitualKeepAlive({
    required int id,
    required RitualId ritual,
    required DateTime firstFireAt,
    required String payload,
  }) async {
    scheduleCalls.add(id);
    pending[id] = RecordedRitualAlarm(ritual, firstFireAt, payload, true);
  }

  @override
  Future<List<({int id, String? payload})>> pendingRitualNotifications() async =>
      [for (final e in pending.entries) (id: e.key, payload: e.value.payload)];

  @override
  Future<List<({int id, RitualId ritual})>> deliveredRitualNotifications() async =>
      List.of(delivered);

  @override
  Future<void> cancelReminder(int id) async {
    cancelledIds.add(id);
    pending.remove(id);
    delivered.removeWhere((d) => d.id == id);
  }

  /// The pending one-off and keep-alive alarms of [ritual], soonest first.
  List<RecordedRitualAlarm> alarmsOf(RitualId ritual) => pending.values
      .where((a) => a.ritual == ritual)
      .toList()
    ..sort((a, b) => a.fireAt.compareTo(b.fireAt));
}

class RecordedRitualAlarm {
  const RecordedRitualAlarm(
      this.ritual, this.fireAt, this.payload, this.isKeepAlive);

  final RitualId ritual;
  final DateTime fireAt;
  final String payload;
  final bool isKeepAlive;
}

/// A [RecordingNotificationService] for tests that only need the plugin kept
/// out of the way.
class StubNotificationService extends RecordingNotificationService {}

/// A `getNeedsReview` cutoff so far ahead that every stored
/// `last_clarified_at` is older than it — the Actionless freshness gate is
/// wide open. For tests about *which* Outcomes are Stale or Actionless that do
/// not exercise the time box itself.
final actionlessGateOpenCutoff = DateTime.utc(2100);
