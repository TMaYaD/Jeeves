/// Turning an Inbox Capture into a Habit (issue #999).
///
/// The write sits on the Habits side and only reads the Capture, so the GTD
/// Core clarification code gains no Habit type.
library;

import '../database/daos/habit_dao.dart';
import '../database/gtd_database.dart';
import 'clarification_service.dart' show CaptureNotFoundError;

/// Makes a Habit of the Inbox Capture [captureId], in one transaction.
///
/// The Habit gets [title] (trimmed) and [notes] (when not blank), the same
/// first commitment a hand-made Habit gets, the Capture's Area and Labels,
/// and the Capture is stamped clarified so it leaves the Inbox. No Outcome is
/// created. The Capture's Project and Person hints are not carried: a Habit
/// has neither, and the hint rows stay on the Capture.
///
/// Throws [CaptureNotFoundError] for a Capture that is missing or already
/// clarified, and an [ArgumentError] for an unusable [title]. Any failure
/// writes nothing, and the Capture stays in the Inbox.
///
/// Returns the new Habit's id.
Future<String> makeHabitFromCapture(
  GtdDatabase db, {
  required String captureId,
  required String title,
  String? notes,
  required String userId,
  required String today,
  DateTime? now,
}) {
  final instant = now ?? DateTime.now();
  return db.capturing(() async {
    final capture = await db.captureDao.getCapture(captureId);
    if (capture == null || capture.clarifiedAt != null) {
      throw CaptureNotFoundError(captureId);
    }
    final habitId = await db.habitDao.createHabit(
      userId: userId,
      title: title.trim(),
      today: today,
      now: instant,
      firstCommitment: defaultNewHabitCommitment,
    );
    final trimmedNotes = notes?.trim();
    if (trimmedNotes != null && trimmedNotes.isNotEmpty) {
      await db.habitDao.updateHabitDetails(
        habitId: habitId,
        userId: userId,
        title: title.trim(),
        notes: trimmedNotes,
        energyLevel: null,
        timeEstimateMinutes: null,
        now: instant,
      );
    }
    final hints = await db.captureDao.tagHintsForCapture(captureId);
    final areas = hints.where((t) => t.type == habitAreaTagType).toList()
      ..sort((a, b) {
        final byName = a.name.compareTo(b.name);
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    if (areas.isNotEmpty) {
      await db.habitDao.setArea(
        habitId: habitId,
        userId: userId,
        areaTagId: areas.first.id,
      );
    }
    for (final tag in hints.where((t) => habitLabelTagTypes.contains(t.type))) {
      await db.habitDao.assignLabel(
        habitId: habitId,
        userId: userId,
        tagId: tag.id,
      );
    }
    await db.captureDao.stampClarified(captureId, at: instant);
    return habitId;
  });
}
