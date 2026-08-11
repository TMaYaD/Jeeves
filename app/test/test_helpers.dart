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

/// No-ops the platform-channel notification calls made by ritual providers
/// (`startDay` / `closeDay` skip today's reminder on close). Unit and widget
/// tests wire this in via `notificationServiceProvider.overrideWithValue(...)`
/// so they never touch a real plugin.
class StubNotificationService extends NotificationService {
  StubNotificationService() : super.forTesting();

  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async {}
}
