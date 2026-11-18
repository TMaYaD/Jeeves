/// DAO for Habits: the local rows of the Habit data model (issue #401).
///
/// A Habit is something the user does regularly, on a rule they chose. The
/// rule and the measurable target live in a **commitment** — an append-only
/// row, so a change of rule never rewrites the commitment an earlier period
/// was judged by. Which commitment governs a day is a pure function
/// (`models/habit_commitment.dart`), not a query.
///
/// **Device-local until Habits sync.** These tables have no codec and author
/// no op, like `capture_attachments`: a store rebuilt from the op log does not
/// bring the Habits back, and they are not in the data export. Every write
/// still runs in [GtdDatabase.capturing], because that is where the
/// transaction boundary is — a bare `transaction` is refused. The transaction
/// is the boundary; the op log is not involved.
///
/// **There is no delete path.** A Habit is paused, archived and restored, and
/// everything it holds survives all three. A Habit that is gone is a Habit the
/// user archived.
///
/// The writes take the user the write is for, the day it is made (`today`, a
/// day key) and an injectable `now`, so a caller decides what "today" means —
/// the day being closed is not always the day the clock says.
library;

import 'package:drift/drift.dart';

import '../../models/habit_commitment.dart';
import '../../sync/collection_codecs.dart' show encodeInstant;
import '../../utils/uuid.dart';
import '../gtd_database.dart';

part 'habit_dao.g.dart';

/// Where a Habit sits in the day.
///
/// The strings are what `habits.anchor_kind` holds. The anchor is **not
/// dated**: it says where the Habit sits in the day, not how much of the day
/// is expected, so it is not a commitment and no copy of it is kept per
/// period.
enum HabitAnchorKind {
  /// No anchor: the Habit is not placed in the day.
  none('none'),

  /// A part of the day: morning, afternoon or evening.
  partOfDay('part_of_day'),

  /// A clock time, local `HH:MM`, 24-hour.
  clockTime('clock_time'),

  /// After another Habit.
  afterHabit('after_habit'),

  /// Before another Habit.
  beforeHabit('before_habit');

  const HabitAnchorKind(this.storedValue);

  /// The string this kind is stored as.
  final String storedValue;

  /// The kind stored as [storedValue], or null when the stored string is not
  /// one of the five.
  ///
  /// A read tolerates a row it does not recognise: a kind written by a later
  /// build is skipped, not a crash.
  static HabitAnchorKind? tryParse(String storedValue) {
    for (final kind in HabitAnchorKind.values) {
      if (kind.storedValue == storedValue) return kind;
    }
    return null;
  }
}

/// The repeat rule and the target of a commitment, before the store knows
/// which Habit it governs.
///
/// The store mints the Habit's id, the commitment's id and the instant it was
/// written, so the caller cannot build a [HabitCommitment] itself. The draft
/// holds what the caller does know; the DAO completes it into a validated
/// [HabitCommitment] before it is written.
class HabitCommitmentDraft {
  const HabitCommitmentDraft({
    required this.repeatKind,
    this.chosenWeekdays,
    this.timesPerPeriod,
    this.intervalDays,
    this.preferredDays,
    this.unitLabel,
    this.dailyTargetAmount,
  });

  /// The repeat rule.
  final HabitRepeatKind repeatKind;

  /// The chosen weekdays, ISO 1 = Monday … 7 = Sunday. Only for
  /// [HabitRepeatKind.chosenWeekdays].
  final List<int>? chosenWeekdays;

  /// N — how many times a week or a month. Only for
  /// [HabitRepeatKind.timesPerWeek] and [HabitRepeatKind.timesPerMonth].
  final int? timesPerPeriod;

  /// The N of "every N days". Only for [HabitRepeatKind.everyNDays].
  final int? intervalDays;

  /// A hint, not a rule: the days the user prefers. Only for the counted
  /// kinds.
  final List<int>? preferredDays;

  /// The unit the target is counted in ("pages", "glasses"). Null for a
  /// binary Habit.
  final String? unitLabel;

  /// How much of one period the target asks for. Set together with
  /// [unitLabel] for a measurable Habit, null for both on a binary one.
  final double? dailyTargetAmount;

  /// The commitment this draft becomes for [habitId], chosen on [chosenOn] and
  /// written at [createdAt].
  ///
  /// Throws an [ArgumentError] when the combination is not a rule the app
  /// accepts — the validation [HabitCommitment] does, so an invalid
  /// commitment never reaches the store.
  HabitCommitment toCommitment({
    required String id,
    required String habitId,
    required String chosenOn,
    required DateTime createdAt,
  }) =>
      HabitCommitment(
        id: id,
        habitId: habitId,
        chosenOn: chosenOn,
        createdAt: createdAt,
        repeatKind: repeatKind,
        chosenWeekdays: chosenWeekdays,
        timesPerPeriod: timesPerPeriod,
        intervalDays: intervalDays,
        preferredDays: preferredDays,
        unitLabel: unitLabel,
        dailyTargetAmount: dailyTargetAmount,
      );
}

/// The three effort levels a Habit can ask for — the values an Action
/// carries, so the Outcome editors the Habit form reuses work on them
/// unchanged.
const Set<String> habitEnergyLevels = {'low', 'medium', 'high'};

/// The three parts of the day a Habit can be anchored to.
const Set<String> habitPartsOfDay = {'morning', 'afternoon', 'evening'};

/// A local clock time, `HH:MM`, 24-hour.
final RegExp habitClockTimePattern = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

@DriftAccessor(tables: [Habits, HabitCommitments, HabitInactivePeriods])
class HabitDao extends DatabaseAccessor<GtdDatabase> with _$HabitDaoMixin {
  HabitDao(super.db);

  // --- writes ---------------------------------------------------------------

  /// Creates a Habit with its first commitment, in one transaction.
  ///
  /// The Habit and the commitment that governs it are one act — a Habit with
  /// no rule is not a Habit yet — so they are written together or not at all.
  /// The commitment is chosen on [today] and written at [now].
  ///
  /// Throws an [ArgumentError] for a name that is empty or longer than 500
  /// characters, and for a first commitment whose rule and target do not go
  /// together.
  ///
  /// Returns the Habit's id.
  Future<String> createHabit({
    required String userId,
    required String title,
    required String today,
    required DateTime now,
    required HabitCommitmentDraft firstCommitment,
  }) async {
    final name = _validatedTitle(title);
    final instant = _storedInstant(now);
    final habitId = uuid.v4();
    final commitment = firstCommitment.toCommitment(
      id: uuid.v4(),
      habitId: habitId,
      chosenOn: today,
      createdAt: instant,
    );
    await attachedDatabase.capturing(() async {
      await into(habits).insert(HabitsCompanion.insert(
            id: Value(habitId),
            userId: userId,
            title: name,
            createdAt: encodeInstant(instant)!,
          ));
      await into(habitCommitments)
          .insert(_commitmentCompanion(commitment, userId));
    });
    return habitId;
  }

  /// Edits a Habit's name, notes, effort and estimate.
  ///
  /// The values are the Habit's new state, not a patch: a null note or
  /// estimate clears the column. The Habit's rule and target are **not**
  /// touched — they live in commitments, and a change there is a new
  /// commitment ([setCommitment]), never a rewrite.
  ///
  /// Stamps `updated_at`.
  ///
  /// Throws an [ArgumentError] for a name that is empty or longer than 500
  /// characters, for an effort that is not low, medium or high, for an
  /// estimate that is not more than zero minutes, and for a Habit that is not
  /// there.
  Future<void> updateHabitDetails({
    required String habitId,
    required String userId,
    required String title,
    required String? notes,
    required String? energyLevel,
    required int? timeEstimateMinutes,
    required DateTime now,
  }) async {
    final name = _validatedTitle(title);
    final effort = _validatedEnergyLevel(energyLevel);
    final estimate = _validatedEstimate(timeEstimateMinutes);
    final instant = _storedInstant(now);
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      await (update(habits)..where((h) => h.id.equals(habitId))).write(
        HabitsCompanion(
          title: Value(name),
          notes: Value(notes),
          energyLevel: Value(effort),
          timeEstimateMinutes: Value(estimate),
          updatedAt: Value(encodeInstant(instant)),
        ),
      );
    });
  }

  /// Appends a commitment for a Habit, chosen on [today].
  ///
  /// **Append-only.** A commitment is never updated and never deleted: the
  /// rule and the target in force on a day are read from the commitments that
  /// were in force when the day came, so a change made now leaves the days
  /// before it judged by the rule they had. A change of rule is therefore a
  /// new commitment, and this is the only way to write one.
  ///
  /// Throws an [ArgumentError] for a Habit that is not there, and for a rule
  /// and target that do not go together.
  ///
  /// Returns the new commitment's id.
  Future<String> setCommitment({
    required String habitId,
    required String userId,
    required String today,
    required DateTime now,
    required HabitCommitmentDraft commitment,
  }) async {
    final instant = _storedInstant(now);
    final commitmentId = uuid.v4();
    // The commitment is built before the transaction opens, so a rule that
    // does not hold together is refused without a transaction at all.
    final built = commitment.toCommitment(
      id: commitmentId,
      habitId: habitId,
      chosenOn: today,
      createdAt: instant,
    );
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      await into(habitCommitments)
          .insert(_commitmentCompanion(built, userId));
      // The Habit's own row is stamped too: its rule just changed.
      await (update(habits)..where((h) => h.id.equals(habitId))).write(
        HabitsCompanion(updatedAt: Value(encodeInstant(instant))),
      );
    });
    return commitmentId;
  }

  /// Places a Habit in the day.
  ///
  /// The value that belongs to the kind must be given and the others must be
  /// absent: `partOfDay` for [HabitAnchorKind.partOfDay], `clockTime` for
  /// [HabitAnchorKind.clockTime], `anchorHabitId` for
  /// [HabitAnchorKind.afterHabit] and [HabitAnchorKind.beforeHabit], and
  /// none of them for [HabitAnchorKind.none].
  ///
  /// An anchor on another Habit is refused when the target is the Habit
  /// itself, when there is no such Habit, when that Habit is archived on
  /// [today], and when the anchor would close a loop — a Habit that follows
  /// one that follows it, directly or through any number of Habits in
  /// between.
  ///
  /// Stamps `updated_at`.
  ///
  /// Throws an [ArgumentError] for an anchor value that does not match the
  /// kind, and for every refusal above.
  Future<void> setAnchor({
    required String habitId,
    required String userId,
    required String today,
    required DateTime now,
    required HabitAnchorKind kind,
    String? partOfDay,
    String? clockTime,
    String? anchorHabitId,
  }) async {
    // The shape of the anchor is checked before anything is read, so a
    // malformed anchor is refused without touching the store.
    final values = _validatedAnchorValues(
      kind: kind,
      partOfDay: partOfDay,
      clockTime: clockTime,
      anchorHabitId: anchorHabitId,
    );
    final instant = _storedInstant(now);
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      final targetId = values.anchorHabitId;
      if (targetId != null) {
        if (targetId == habitId) {
          throw ArgumentError.value(targetId, 'anchorHabitId',
              'A Habit cannot be anchored to itself.');
        }
        if (await habitById(targetId) == null) {
          throw ArgumentError.value(
              targetId, 'anchorHabitId', 'There is no Habit with that id.');
        }
        if (await _isArchivedOn(targetId, today)) {
          throw ArgumentError.value(targetId, 'anchorHabitId',
              'An archived Habit cannot be the anchor of another Habit.');
        }
        if (await _anchorChainReaches(habitId, targetId)) {
          throw ArgumentError.value(targetId, 'anchorHabitId',
              'That anchor would loop: the Habit already follows it.');
        }
      }
      await (update(habits)..where((h) => h.id.equals(habitId))).write(
        HabitsCompanion(
          anchorKind: Value(kind.storedValue),
          anchorPartOfDay: Value(values.partOfDay),
          anchorClockTime: Value(values.clockTime),
          anchorHabitId: Value(values.anchorHabitId),
          updatedAt: Value(encodeInstant(instant)),
        ),
      );
    });
  }

  // --- reads ----------------------------------------------------------------

  /// The Habit with [habitId], or null when there is none.
  Future<Habit?> habitById(String habitId) =>
      (select(habits)..where((h) => h.id.equals(habitId))).getSingleOrNull();

  /// The Habit's commitments, oldest first.
  ///
  /// A row the app does not understand — an unknown repeat kind, or a
  /// combination the model refuses — is skipped rather than crashing the
  /// read: the reads tolerate what they meet.
  Future<List<HabitCommitment>> commitmentsFor(String habitId) async {
    final rows = await (select(habitCommitments)
          ..where((c) => c.habitId.equals(habitId))
          ..orderBy([
            (c) => OrderingTerm.asc(c.createdAt),
            (c) => OrderingTerm.asc(c.id),
          ]))
        .get();
    final commitments = <HabitCommitment>[];
    for (final row in rows) {
      final commitment = _toCommitment(row);
      if (commitment != null) commitments.add(commitment);
    }
    return commitments;
  }

  // --- internals ------------------------------------------------------------

  /// The Habit's row, or an [ArgumentError] when there is no such Habit or it
  /// belongs to another user.
  ///
  /// The owner is checked because the commitment rows carry a `user_id` of
  /// their own: a commitment that claimed another user would be a row that
  /// disagreed with the Habit it governs.
  Future<Habit> _requireHabit(String habitId, String userId) async {
    final habit = await habitById(habitId);
    if (habit == null) {
      throw ArgumentError.value(
          habitId, 'habitId', 'There is no Habit with that id.');
    }
    if (habit.userId != userId) {
      throw ArgumentError.value(
          habitId, 'habitId', 'The Habit belongs to another user.');
    }
    return habit;
  }

  /// Whether the Habit is archived on [dayKey].
  ///
  /// The state is **derived**, never stored: a day is archived when an
  /// archived period covers it. A period covers a day when it starts on or
  /// before that day and has not ended before it.
  Future<bool> _isArchivedOn(String habitId, String dayKey) async {
    final periods = await (select(habitInactivePeriods)
          ..where((p) =>
              p.habitId.equals(habitId) & p.kind.equals('archived')))
        .get();
    for (final period in periods) {
      if (period.startsOn.compareTo(dayKey) > 0) continue;
      final endsBefore = period.endsBefore;
      if (endsBefore != null && dayKey.compareTo(endsBefore) >= 0) continue;
      return true;
    }
    return false;
  }

  /// Whether the chain of anchors from [targetId] reaches [habitId].
  ///
  /// A Habit anchored after another, that other anchored after a third, and
  /// the first anchored after the third — that is a loop, and it leaves "what
  /// follows this Habit?" unanswerable. The walk stops at [habitId] without
  /// reading its own anchor, because that is the edge being written.
  Future<bool> _anchorChainReaches(String habitId, String targetId) async {
    var current = targetId;
    final seen = <String>{};
    while (true) {
      if (current == habitId) return true;
      // A loop that is not ours is somebody else's problem, and it cannot
      // make this anchor a loop.
      if (!seen.add(current)) return false;
      final row = await habitById(current);
      if (row == null) return false;
      final next = row.anchorHabitId;
      if (next == null) return false;
      current = next;
    }
  }

  /// The row a commitment is stored as.
  ///
  /// The user is the Habit's owner, passed in because the commitment's own
  /// `user_id` is the one column the value the caller holds does not carry.
  static HabitCommitmentsCompanion _commitmentCompanion(
          HabitCommitment commitment, String userId) =>
      HabitCommitmentsCompanion.insert(
        id: Value(commitment.id),
        userId: userId,
        habitId: commitment.habitId,
        chosenOn: commitment.chosenOn,
        createdAt: encodeInstant(commitment.createdAt)!,
        repeatKind: commitment.repeatKind.storedValue,
        chosenWeekdays: Value(commitment.chosenWeekdaysJson),
        timesPerPeriod: Value(commitment.timesPerPeriod),
        intervalDays: Value(commitment.intervalDays),
        preferredDays: Value(commitment.preferredDaysJson),
        unitLabel: Value(commitment.unitLabel),
        dailyTargetAmount: Value(commitment.dailyTargetAmount),
      );

  /// The commitment a row holds, or null when the row is not one the app
  /// understands.
  static HabitCommitment? _toCommitment(HabitCommitmentRow row) {
    final repeatKind = HabitRepeatKind.tryParse(row.repeatKind);
    if (repeatKind == null) return null;
    final createdAt = DateTime.tryParse(row.createdAt);
    if (createdAt == null) return null;
    try {
      return HabitCommitment(
        id: row.id,
        habitId: row.habitId,
        chosenOn: row.chosenOn,
        createdAt: createdAt.toUtc(),
        repeatKind: repeatKind,
        chosenWeekdays: parseDayListJson(row.chosenWeekdays),
        timesPerPeriod: row.timesPerPeriod,
        intervalDays: row.intervalDays,
        preferredDays: parseDayListJson(row.preferredDays),
        unitLabel: row.unitLabel,
        dailyTargetAmount: row.dailyTargetAmount,
      );
    } on ArgumentError {
      // A combination the app refuses is a row some other build wrote. The
      // read skips it rather than refusing the whole Habit.
      return null;
    }
  }

  /// The instant a write is stamped with: UTC, truncated to the millisecond,
  /// which is exactly what [encodeInstant] stores — so the commitment a
  /// write builds is the commitment a later read gives back.
  static DateTime _storedInstant(DateTime now) {
    final utc = now.toUtc();
    return DateTime.fromMillisecondsSinceEpoch(
      utc.millisecondsSinceEpoch,
      isUtc: true,
    );
  }

  /// The Habit's name, trimmed and checked.
  static String _validatedTitle(String title) {
    final name = title.trim();
    if (name.isEmpty) {
      throw ArgumentError.value(title, 'title', 'A Habit needs a name.');
    }
    if (name.length > 500) {
      throw ArgumentError.value(
          title, 'title', 'A Habit name is 500 characters at most.');
    }
    return name;
  }

  /// The effort a Habit asks for, or null for a Habit that asks for none.
  static String? _validatedEnergyLevel(String? energyLevel) {
    if (energyLevel == null) return null;
    if (!habitEnergyLevels.contains(energyLevel)) {
      throw ArgumentError.value(energyLevel, 'energyLevel',
          'The effort a Habit asks for is low, medium or high.');
    }
    return energyLevel;
  }

  /// How long a Habit takes, in minutes, or null when it is not known.
  static int? _validatedEstimate(int? minutes) {
    if (minutes == null) return null;
    if (minutes <= 0) {
      throw ArgumentError.value(minutes, 'timeEstimateMinutes',
          'A Habit takes more than zero minutes.');
    }
    return minutes;
  }

  /// The anchor values that belong to [kind], checked.
  ///
  /// Only the value the kind names may be given, and it must be a value the
  /// app accepts: a part of the day is one of the three, a clock time is a
  /// local `HH:MM`, and an anchor on another Habit names a Habit.
  static ({
    String? partOfDay,
    String? clockTime,
    String? anchorHabitId,
  }) _validatedAnchorValues({
    required HabitAnchorKind kind,
    String? partOfDay,
    String? clockTime,
    String? anchorHabitId,
  }) {
    String? allowedPartOfDay;
    String? allowedClockTime;
    String? allowedHabitId;

    switch (kind) {
      case HabitAnchorKind.none:
        break;
      case HabitAnchorKind.partOfDay:
        if (partOfDay == null || !habitPartsOfDay.contains(partOfDay)) {
          throw ArgumentError.value(partOfDay, 'partOfDay',
              'A part of the day is morning, afternoon or evening.');
        }
        allowedPartOfDay = partOfDay;
        break;
      case HabitAnchorKind.clockTime:
        if (clockTime == null || !habitClockTimePattern.hasMatch(clockTime)) {
          throw ArgumentError.value(
              clockTime, 'clockTime', 'A clock time is a local HH:MM, 24-hour.');
        }
        allowedClockTime = clockTime;
        break;
      case HabitAnchorKind.afterHabit:
      case HabitAnchorKind.beforeHabit:
        if (anchorHabitId == null) {
          throw ArgumentError.value(anchorHabitId, 'anchorHabitId',
              'An anchor on another Habit needs the Habit it points at.');
        }
        allowedHabitId = anchorHabitId;
        break;
    }

    if (partOfDay != null && partOfDay != allowedPartOfDay) {
      throw ArgumentError.value(
          partOfDay, 'partOfDay', _anchorValueMismatch);
    }
    if (clockTime != null && clockTime != allowedClockTime) {
      throw ArgumentError.value(
          clockTime, 'clockTime', _anchorValueMismatch);
    }
    if (anchorHabitId != null && anchorHabitId != allowedHabitId) {
      throw ArgumentError.value(
          anchorHabitId, 'anchorHabitId', _anchorValueMismatch);
    }

    return (
      partOfDay: allowedPartOfDay,
      clockTime: allowedClockTime,
      anchorHabitId: allowedHabitId,
    );
  }

  static const String _anchorValueMismatch =
      'The anchor value does not match the anchor kind.';
}
