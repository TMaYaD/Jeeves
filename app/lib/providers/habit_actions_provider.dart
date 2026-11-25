/// Every write the Habit screens make. Screens call these; they never touch
/// the DAO (a screen holds no persistence, providers are the seam tests drive).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/habit_dao.dart';
import '../models/habit_commitment.dart';
import '../models/place_area.dart';
import '../widgets/place_pin_sheet.dart' show PinChoice;
import 'auth_provider.dart';
import 'clock_provider.dart';
import 'database_provider.dart';

/// Everything a new Habit holds before it is written.
class HabitDraftValues {
  const HabitDraftValues({
    required this.title,
    required this.notes,
    required this.energyLevel,
    required this.estimateMinutes,
    required this.commitment,
    required this.anchorKind,
    required this.anchorPartOfDay,
    required this.anchorClockTime,
    required this.anchorHabitId,
    required this.areaTagId,
    required this.labelTagIds,
    this.placeId,
    this.pin,
  });

  final String title;
  final String? notes;
  final String? energyLevel;
  final int? estimateMinutes;
  final HabitCommitmentDraft commitment;
  final HabitAnchorKind anchorKind;
  final String? anchorPartOfDay;
  final String? anchorClockTime;
  final String? anchorHabitId;
  final String? areaTagId;
  final List<String> labelTagIds;

  /// The named Place the new Habit will carry, or null for none.
  final String? placeId;

  /// The one-time pin the new Habit will carry, written with it.
  final PinChoice? pin;
}

/// The Habit screens' writes. Each reads the user and the clock when called.
class HabitActions {
  HabitActions(this._ref);

  final Ref _ref;

  HabitDao get _dao => _ref.read(databaseProvider).habitDao;
  String get _userId => _ref.read(currentUserIdProvider);
  DateTime get _now => _ref.read(clockProvider)();
  String get _today => habitDayKey(_now);

  /// Writes a new Habit with every field it holds, in one transaction.
  /// Returns its id.
  Future<String> createFromDraft(HabitDraftValues draft) async {
    final db = _ref.read(databaseProvider);
    final userId = _userId;
    final now = _now;
    final today = habitDayKey(now);
    final notes = draft.notes?.trim() ?? '';
    return db.capturing(() async {
      final dao = db.habitDao;
      final id = await dao.createHabit(
        userId: userId,
        title: draft.title,
        today: today,
        now: now,
        firstCommitment: draft.commitment,
        placeId: draft.placeId,
        pinArea: draft.pin?.area,
        pinName: draft.pin?.name,
      );
      if (notes.isNotEmpty ||
          draft.energyLevel != null ||
          draft.estimateMinutes != null) {
        await dao.updateHabitDetails(
          habitId: id,
          userId: userId,
          title: draft.title,
          notes: notes.isEmpty ? null : notes,
          energyLevel: draft.energyLevel,
          timeEstimateMinutes: draft.estimateMinutes,
          now: now,
        );
      }
      if (draft.areaTagId != null) {
        await dao.setArea(
          habitId: id,
          userId: userId,
          areaTagId: draft.areaTagId,
        );
      }
      for (final tagId in draft.labelTagIds) {
        await dao.assignLabel(habitId: id, userId: userId, tagId: tagId);
      }
      if (draft.anchorKind != HabitAnchorKind.none) {
        await dao.setAnchor(
          habitId: id,
          userId: userId,
          today: today,
          now: now,
          kind: draft.anchorKind,
          partOfDay: draft.anchorPartOfDay,
          clockTime: draft.anchorClockTime,
          anchorHabitId: draft.anchorHabitId,
        );
      }
      return id;
    });
  }

  /// Changes only the fields passed, keeping the rest as the store holds them
  /// now (read inside the write), never as an editor saw them when it opened.
  Future<void> _patchDetails(
    String habitId, {
    String? title,
    bool setNotes = false,
    String? notes,
    bool setEnergy = false,
    String? energyLevel,
    bool setEstimate = false,
    int? estimateMinutes,
  }) async {
    final db = _ref.read(databaseProvider);
    final userId = _userId;
    final now = _now;
    await db.capturing(() async {
      final habit = await db.habitDao.habitById(habitId);
      if (habit == null) return;
      await db.habitDao.updateHabitDetails(
        habitId: habitId,
        userId: userId,
        title: title ?? habit.title,
        notes: setNotes ? notes : habit.notes,
        energyLevel: setEnergy ? energyLevel : habit.energyLevel,
        timeEstimateMinutes: setEstimate
            ? estimateMinutes
            : habit.timeEstimateMinutes,
        now: now,
      );
    });
  }

  /// Saves [title] unless it is empty or already what is stored.
  /// Returns false when it was refused for being empty.
  Future<bool> setTitle(String habitId, String title) async {
    final text = title.trim();
    if (text.isEmpty) return false;
    final habit = await _dao.habitById(habitId);
    if (habit == null || habit.title == text) return true;
    await _patchDetails(habitId, title: text);
    return true;
  }

  /// Saves [notes] (blank clears them) unless already what is stored.
  Future<void> setNotes(String habitId, String notes) async {
    final text = notes.trim();
    final next = text.isEmpty ? null : text;
    final habit = await _dao.habitById(habitId);
    if (habit == null || habit.notes == next) return;
    await _patchDetails(habitId, setNotes: true, notes: next);
  }

  Future<void> setEnergy(String habitId, String? level) =>
      _patchDetails(habitId, setEnergy: true, energyLevel: level);

  Future<void> setEstimate(String habitId, int? minutes) =>
      _patchDetails(habitId, setEstimate: true, estimateMinutes: minutes);

  Future<void> setCommitment(String habitId, HabitCommitmentDraft next) =>
      _dao.setCommitment(
        habitId: habitId,
        userId: _userId,
        today: _today,
        now: _now,
        commitment: next,
      );

  Future<void> setAnchor(
    String habitId, {
    required HabitAnchorKind kind,
    String? partOfDay,
    String? clockTime,
    String? anchorHabitId,
  }) => _dao.setAnchor(
    habitId: habitId,
    userId: _userId,
    today: _today,
    now: _now,
    kind: kind,
    partOfDay: partOfDay,
    clockTime: clockTime,
    anchorHabitId: anchorHabitId,
  );

  Future<void> setArea(String habitId, String? areaTagId) =>
      _dao.setArea(habitId: habitId, userId: _userId, areaTagId: areaTagId);

  Future<void> assignLabel(String habitId, String tagId) =>
      _dao.assignLabel(habitId: habitId, userId: _userId, tagId: tagId);

  Future<void> unassignLabel(String habitId, String tagId) =>
      _dao.unassignLabel(habitId: habitId, userId: _userId, tagId: tagId);

  /// Sets the named Place of the Habit, or clears it when [placeId] is null
  /// (issue #1075).
  ///
  /// A Place that does not exist, or a one-time pin, is refused: a pin is
  /// set with [setPin]. A Habit that already carries that Place is left as it
  /// is.
  Future<void> setNamedPlace(String habitId, String? placeId) async {
    await _dao.setNamedPlace(habitId, placeId, now: _now);
  }

  /// Drops a one-time pin for the Habit — a Place of this Habit's own.
  ///
  /// Answers whether the pin was written: a pin that was not written is no
  /// Place saved, so nothing follows it.
  Future<bool> setPin(String habitId, PlaceArea area, {String? name}) async {
    final pinId = await _dao.setPin(habitId, area, name: name, now: _now);
    return pinId != null;
  }

  /// Takes the Habit's Place away.
  ///
  /// A one-time pin the Habit carried goes with it: the pin belongs to the
  /// one thing that points at it. A named Place stays in the user's list.
  Future<void> clearPlace(String habitId) async {
    await _dao.setNamedPlace(habitId, null, now: _now);
  }

  Future<void> pause(String habitId, {String? resumesOn}) => _dao.pause(
    habitId: habitId,
    userId: _userId,
    today: _today,
    now: _now,
    resumesOn: resumesOn,
  );

  Future<void> resume(String habitId) => _dao.resume(
    habitId: habitId,
    userId: _userId,
    today: _today,
    now: _now,
  );

  Future<void> archive(String habitId) => _dao.archive(
    habitId: habitId,
    userId: _userId,
    today: _today,
    now: _now,
  );

  Future<void> restore(String habitId) => _dao.restore(
    habitId: habitId,
    userId: _userId,
    today: _today,
    now: _now,
  );
}

final habitActionsProvider = Provider<HabitActions>(HabitActions.new);
