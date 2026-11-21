/// Turns an Inbox Capture into a Habit (#999).
///
/// Sits on the Habits side and reads the Capture, so the GTD Core clarify code
/// gains no Habit type. The verdict is the same as "Done with this Capture" —
/// stamp `clarified_at`, create no Outcome — plus a Habit.
library;

import '../database/daos/habit_dao.dart';
import '../database/gtd_database.dart';
import 'clarification_service.dart' show CaptureNotFoundError;

/// Creates a Habit from the Inbox Capture [captureId], in one transaction.
///
/// 1. Creates the Habit titled [title] with the default commitment (every day,
///    binary), and with [notes] when they are not blank.
/// 2. Carries the Capture's Area (the first `area` hint by name) and its
///    Labels (`context` and `label` hints). Project and Person hints are not
///    carried: a Habit has neither. They stay on the Capture as its record.
/// 3. Stamps the Capture clarified, so it leaves the Inbox.
///
/// Throws [CaptureNotFoundError] when the Capture is gone or already
/// clarified, and an [ArgumentError] for a blank or too long [title]. Either
/// way nothing is written.
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
  return db.capturing(() async {
    final capture = await db.captureDao.getCapture(captureId);
    if (capture == null || capture.clarifiedAt != null) {
      throw CaptureNotFoundError(captureId);
    }
    final moment = now ?? DateTime.now();
    final habitId = await db.habitDao.createHabit(
      userId: userId,
      title: title,
      today: today,
      now: moment,
      firstCommitment: defaultNewHabitCommitment,
    );
    final trimmedNotes = notes?.trim();
    if (trimmedNotes != null && trimmedNotes.isNotEmpty) {
      await db.habitDao.updateHabitDetails(
        habitId: habitId,
        userId: userId,
        title: title,
        notes: trimmedNotes,
        energyLevel: null,
        timeEstimateMinutes: null,
        now: moment,
      );
    }
    // The DAO orders hints by name, so the first Area is the first by name.
    final hints = await db.captureDao.tagHintsForCapture(captureId);
    final areas = hints.where((t) => t.type == habitAreaTagType);
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
    await db.captureDao.stampClarified(captureId, at: moment);
    return habitId;
  });
}
