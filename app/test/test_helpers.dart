import 'package:drift/drift.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/ritual.dart';
import 'package:jeeves/services/notification_service.dart';

/// Call once before any test that uses [NativeDatabase].
///
/// sqlite3 >=3.0 loads the native library via build hooks rather than
/// runtime [DynamicLibrary] overrides, so no manual path fixup is needed.
void configureSqliteForTests() {}

/// Seeds the `current` Action row that mirrors [text] for [outcomeId] — the
/// dual-write invariant every next-action write path upholds (ADR-0001 story
/// 2) and the grain every read consults from story 3 on.
///
/// Fixtures that write `todos.next_action_text` directly (bypassing
/// `TodoDao.setNextActionText`) call this so the two sides agree, exactly as
/// they would in production. A blank or null [text] seeds nothing, mirroring
/// the blank → Actionless normalisation `setNextActionText` applies.
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

/// No-ops the platform-channel notification calls made by ritual providers
/// (`startDay` / `closeDay` skip today's reminder on close). Unit and widget
/// tests wire this in via `notificationServiceProvider.overrideWithValue(...)`
/// so they never touch a real plugin.
class StubNotificationService extends NotificationService {
  StubNotificationService() : super.forTesting();

  @override
  Future<void> skipTodayRitualReminder(RitualId ritual) async {}
}
