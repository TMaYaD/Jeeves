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
/// user archived. A Check-in can be taken back, because a user who checked in
/// by mistake means to take it back — that is a correction, not a delete path
/// for a Habit.
///
/// The writes take the user the write is for. A write that stamps an instant
/// takes an injectable `now`, and a write that takes effect on a day takes
/// that day as `today`, so a caller decides what "today" means — the day
/// being closed is not always the day the clock says. A pause, an archive and
/// a restore take the day they take effect on and stamp the Habit as edited.
library;

import 'package:drift/drift.dart';
import 'package:uuid/enums.dart' show Namespace;

import '../../models/habit_commitment.dart';
import '../../models/habit_progress.dart' show HabitHistory;
import '../../sync/collection_codecs.dart' show encodeInstant;
import '../../utils/uuid.dart';
import '../gtd_database.dart';

part 'habit_dao.g.dart';

/// Deterministic `habit_tags.id` for the (habitId, tagId) pair.
///
/// The junction row's logical identity is the pair, so the id is derived from
/// it: writing the same pair twice lands on the same row instead of
/// accumulating duplicates, and a merge that moves a row onto a pair that
/// already holds one collapses onto it.
String habitTagIdFor(String habitId, String tagId) =>
    uuid.v5(Namespace.url.value, 'jeeves://habit_tag/$habitId/$tagId');

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

/// Where a Habit sits in its life on a given day.
///
/// The state is **derived**, never stored: it is read from the dated pause and
/// archive periods that cover the day. A day covered by an archived period is
/// archived; a day covered by a paused period and by no archived one is
/// paused; anything else is active.
///
/// The two words that are not `active` are the words the period rows carry
/// (`habit_inactive_periods.kind`), so a state and the period it comes from
/// never disagree about what they are called.
enum HabitState {
  /// The Habit is live: not paused and not archived.
  active,

  /// The Habit is paused on that day.
  paused,

  /// The Habit is archived on that day.
  archived,
}

/// A Habit and the state it is in on a given day.
///
/// The pair is what a list of Habits needs: the Habit and where it stands
/// that day. The state is read from the Habit's periods, so it is never
/// stored beside the Habit.
class HabitWithState {
  /// The Habit.
  final Habit habit;

  /// The state of the Habit on the day that was asked for.
  final HabitState state;

  /// The pair of a Habit and its state.
  const HabitWithState({required this.habit, required this.state});
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

/// The tag types a Label may be.
///
/// A Label is a tag the Outcome Labels editor offers. `context` is in the set
/// because #997 has not decided which of the two the `context` rows are, and
/// a Habit should take the Labels the user can see wherever they live. An
/// Area, a Project and a Person are not Labels: an Area is set with
/// `setArea` and there is one per Habit, and a Project and a Person belong to
/// an Outcome.
const Set<String> habitLabelTagTypes = {'label', 'context'};

/// The tag type an Area is.
const String habitAreaTagType = 'area';

/// A local clock time, `HH:MM`, 24-hour.
final RegExp habitClockTimePattern = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

/// The kind of a period in which the Habit is paused.
const String _pausedKind = 'paused';

/// The kind of a period in which the Habit is archived.
const String _archivedKind = 'archived';

@DriftAccessor(tables: [
  Habits,
  HabitCommitments,
  HabitCheckIns,
  HabitInactivePeriods,
  HabitTags,
  Tags,
])
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
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      final existing = await commitmentsFor(habitId);
      // Stored instants have millisecond precision, so two commitments
      // written within one millisecond would tie and the random id would
      // pick the winner. The later write always gets a later instant.
      var createdAt = instant;
      for (final other in existing) {
        final otherAt = other.createdAt.toUtc();
        if (!createdAt.isAfter(otherAt)) {
          createdAt = otherAt.add(const Duration(milliseconds: 1));
        }
      }
      // Built inside the transaction only so that createdAt is final; a rule
      // that does not hold together still throws before anything is written.
      final built = commitment.toCommitment(
        id: commitmentId,
        habitId: habitId,
        chosenOn: today,
        createdAt: _storedInstant(createdAt),
      );
      await _requireCheckInsStillMatch(
          habitId, existing, [...existing, built], built);
      await into(habitCommitments)
          .insert(_commitmentCompanion(built, userId));
      // The Habit's own row is stamped too: its rule just changed.
      await _stampEdited(habitId, instant);
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
    final day = _validatedDay(today, 'today');
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
        if (await _isArchivedOn(targetId, day)) {
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

  /// Records that the user did the Habit on [countsForDay].
  ///
  /// A day can hold several Check-ins — two glasses of water are two
  /// Check-ins, not one row with a count of two — so every call adds a row
  /// and none of them replaces another.
  ///
  /// The day can be any day, including one that is past: a user catches up
  /// on what they did yesterday.
  ///
  /// **A Check-in carries no copy of the target.** What the day's Check-ins
  /// are read against is the commitment in force that day, so a Check-in
  /// added before a target change is judged by the old target and one added
  /// after it by the new one. That is why the amount is checked against the
  /// commitment in force on [countsForDay]: a measurable Habit needs an
  /// amount, and a binary one refuses it.
  ///
  /// Throws an [ArgumentError] for a Habit that is not there, for a day that
  /// is not a day, for an amount that is not more than zero, for an amount on
  /// a binary Habit's day, and for a missing amount on a measurable one.
  ///
  /// Returns the Check-in's id.
  Future<String> addCheckIn({
    required String habitId,
    required String userId,
    required String countsForDay,
    required DateTime now,
    double? measuredAmount,
  }) async {
    final day = _validatedDay(countsForDay, 'countsForDay');
    final amount = _validatedAmount(measuredAmount);
    final instant = _storedInstant(now);
    final checkInId = uuid.v4();
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      await _requireAmountMatches(habitId, day, amount);
      await into(habitCheckIns).insert(HabitCheckInsCompanion.insert(
            id: Value(checkInId),
            userId: userId,
            habitId: habitId,
            countsForDay: day,
            checkedInAt: encodeInstant(instant)!,
            measuredAmount: Value(amount),
          ));
    });
    return checkInId;
  }

  /// Changes how much a Check-in says was done.
  ///
  /// The Check-in keeps its day and its time; only the amount moves. The new
  /// amount is held to the same rule as a new Check-in: it must be more than
  /// zero, a measurable Habit's Check-in keeps an amount, and a binary one's
  /// has none.
  ///
  /// Throws an [ArgumentError] for a Check-in that is not there, for an
  /// amount that is not more than zero, and for an amount that the Habit's
  /// commitment on that day does not allow.
  Future<void> changeCheckInAmount({
    required String checkInId,
    required String userId,
    double? measuredAmount,
  }) async {
    final amount = _validatedAmount(measuredAmount);
    await attachedDatabase.capturing(() async {
      final checkIn = await _requireCheckIn(checkInId, userId);
      await _requireAmountMatches(checkIn.habitId, checkIn.countsForDay, amount);
      await (update(habitCheckIns)..where((c) => c.id.equals(checkInId))).write(
            HabitCheckInsCompanion(measuredAmount: Value(amount)),
          );
    });
  }

  /// Removes a Check-in.
  ///
  /// **This is a user correction, not a delete path for a Habit.** A user
  /// who checked in by mistake takes the Check-in back; the Habit, its
  /// commitments and its other Check-ins are untouched.
  ///
  /// Throws an [ArgumentError] for a Check-in that is not there.
  Future<void> removeCheckIn({
    required String checkInId,
    required String userId,
  }) async {
    await attachedDatabase.capturing(() async {
      await _requireCheckIn(checkInId, userId);
      await (delete(habitCheckIns)..where((c) => c.id.equals(checkInId))).go();
    });
  }

  /// Pauses a Habit from [today].
  ///
  /// A pause with an end date ends by itself: [resumesOn] is the first day
  /// the Habit is active again, and no timer is needed to end it. A pause
  /// without one stays paused until the user resumes it.
  ///
  /// The pause changes nothing else about the Habit: its Check-ins and its
  /// commitments are kept, and the days before the pause still read the
  /// commitment they were judged by.
  ///
  /// Throws an [ArgumentError] for a Habit that is not there, for a Habit
  /// that is already paused or archived on [today], for a [resumesOn] that
  /// is not a day, and for a [resumesOn] that is on or before [today] — a
  /// pause that ends the day it starts is no pause at all.
  Future<void> pause({
    required String habitId,
    required String userId,
    required String today,
    required DateTime now,
    String? resumesOn,
  }) async {
    final startDay = _validatedDay(today, 'today');
    final endDay =
        resumesOn == null ? null : _validatedDay(resumesOn, 'resumesOn');
    final instant = _storedInstant(now);
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      final state = await stateOn(habitId, startDay);
      if (state == HabitState.paused) {
        throw ArgumentError.value(
            habitId, 'habitId', 'The Habit is already paused on that day.');
      }
      if (state == HabitState.archived) {
        throw ArgumentError.value(
            habitId, 'habitId', 'An archived Habit cannot be paused.');
      }
      if (endDay != null && endDay.compareTo(startDay) <= 0) {
        throw ArgumentError.value(resumesOn, 'resumesOn',
            'A pause ends after the day it starts.');
      }
      // The whole interval must be free, not only its first day: a pause that
      // reaches into a later pause or archive would name a first active day
      // the Habit is not active on. A pause may end on the day another period
      // starts.
      final overlapping = (await _periodsFor(habitId)).any((p) =>
          (endDay == null || p.startsOn.compareTo(endDay) < 0) &&
          (p.endsBefore == null || p.endsBefore!.compareTo(startDay) > 0));
      if (overlapping) {
        throw ArgumentError.value(habitId, 'habitId',
            'The pause would overlap a pause or archive of the Habit.');
      }
      await into(habitInactivePeriods).insert(HabitInactivePeriodsCompanion.insert(
            id: Value(uuid.v4()),
            userId: userId,
            habitId: habitId,
            kind: _pausedKind,
            startsOn: startDay,
            endsBefore: Value(endDay),
          ));
      await _stampEdited(habitId, instant);
    });
  }

  /// Ends a Habit's pause at [today], so the Habit is active from that day.
  ///
  /// The pause keeps the days it covered: the Habit was paused on them, and
  /// a later day does not make that untrue.
  ///
  /// Throws an [ArgumentError] for a Habit that is not there, for an
  /// archived Habit, and for a Habit that is not paused.
  Future<void> resume({
    required String habitId,
    required String userId,
    required String today,
    required DateTime now,
  }) async {
    final day = _validatedDay(today, 'today');
    final instant = _storedInstant(now);
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      final state = await stateOn(habitId, day);
      if (state == HabitState.archived) {
        throw ArgumentError.value(
            habitId, 'habitId', 'An archived Habit cannot be resumed.');
      }
      if (state != HabitState.paused) {
        throw ArgumentError.value(
            habitId, 'habitId', 'The Habit is not paused.');
      }
      await _closePauseCovering(habitId, day);
      await _stampEdited(habitId, instant);
    });
  }

  /// Archives a Habit from [today].
  ///
  /// **Archiving is not deleting.** Everything the Habit holds — its
  /// Check-ins, its commitments and its pauses — stays, and the Habit can be
  /// restored. The archived period carries the days it covers, so whether
  /// those days count as missed is a later question the dates can answer.
  ///
  /// An open pause is closed at [today]: a Habit is paused and archived at
  /// the same time is a contradiction, and the archive is the one that
  /// stands.
  ///
  /// Throws an [ArgumentError] for a Habit that is not there and for a Habit
  /// that is already archived.
  Future<void> archive({
    required String habitId,
    required String userId,
    required String today,
    required DateTime now,
  }) async {
    final day = _validatedDay(today, 'today');
    final instant = _storedInstant(now);
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      final state = await stateOn(habitId, day);
      if (state == HabitState.archived) {
        throw ArgumentError.value(
            habitId, 'habitId', 'The Habit is already archived.');
      }
      // A pause that starts after the archive day would end before it
      // starts, so the archive is refused rather than leave an inverted row.
      final laterPause = await (select(habitInactivePeriods)
            ..where((p) =>
                p.habitId.equals(habitId) &
                p.kind.equals(_pausedKind) &
                p.startsOn.isBiggerThanValue(day)))
          .get();
      if (laterPause.isNotEmpty) {
        throw ArgumentError.value(day, 'today',
            'The Habit has a pause that starts after that day.');
      }
      await _closePauseCovering(habitId, day);
      await into(habitInactivePeriods).insert(HabitInactivePeriodsCompanion.insert(
            id: Value(uuid.v4()),
            userId: userId,
            habitId: habitId,
            kind: _archivedKind,
            startsOn: day,
          ));
      await _stampEdited(habitId, instant);
    });
  }

  /// Ends a Habit's archive at [today], so the Habit is active from that day.
  ///
  /// The archived days stay archived: the Habit was archived on them, and
  /// restoring it now does not make that untrue.
  ///
  /// Throws an [ArgumentError] for a Habit that is not there and for a Habit
  /// that is not archived.
  Future<void> restore({
    required String habitId,
    required String userId,
    required String today,
    required DateTime now,
  }) async {
    final day = _validatedDay(today, 'today');
    final instant = _storedInstant(now);
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      final state = await stateOn(habitId, day);
      if (state != HabitState.archived) {
        throw ArgumentError.value(
            habitId, 'habitId', 'The Habit is not archived.');
      }
      await (update(habitInactivePeriods)..where((p) =>
              p.habitId.equals(habitId) &
              p.kind.equals(_archivedKind) &
              p.startsOn.isSmallerOrEqualValue(day) &
              (p.endsBefore.isNull() | p.endsBefore.isBiggerThanValue(day))))
          .write(HabitInactivePeriodsCompanion(endsBefore: Value(day)));
      await _stampEdited(habitId, instant);
    });
  }

  // --- Area and Labels ------------------------------------------------------

  /// Sets the Habit's Area, replacing the Area it already has.
  ///
  /// **A Habit has at most one Area.** The Area is the part of life the Habit
  /// belongs to, and two of them would say the Habit belongs to two places at
  /// once — so giving a new Area takes the old one away, and giving null
  /// takes the Area away and leaves the Habit with none.
  ///
  /// A row whose tag has no row of its own goes too: the tag was deleted
  /// where the Habit could not see it, and a row pointing at nothing says
  /// nothing about what the Habit holds.
  ///
  /// Throws an [ArgumentError] for a Habit that is not there, for a tag that
  /// is not there, and for a tag that is not an `area` tag — a Label given as
  /// an Area would be a row that lies about what it is.
  Future<void> setArea({
    required String habitId,
    required String userId,
    required String? areaTagId,
  }) async {
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      // The Area is checked before the old one is taken away, so a refused
      // Area leaves the Habit with the Area it had.
      final tag = areaTagId == null ? null : await _requireTag(areaTagId);
      if (tag != null && tag.type != habitAreaTagType) {
        throw ArgumentError.value(areaTagId, 'areaTagId',
            'An Area is an area tag, not a ${tag.type} tag.');
      }
      await _removeAreaRows(habitId);
      if (tag == null) return;
      await _insertHabitTag(habitId, tag.id, userId);
    });
  }

  /// Gives the Habit a Label.
  ///
  /// A Habit takes any number of Labels. Which tags may be one is
  /// [habitLabelTagTypes] — the tags the Outcome Labels editor offers.
  ///
  /// An Area, a Project and a Person are refused: an Area is set with
  /// [setArea] and there is one per Habit, and a Project and a Person belong
  /// to an Outcome. A row carrying one of them here would be a claim the
  /// Habit has no business making.
  ///
  /// Throws an [ArgumentError] for a Habit that is not there, for a tag that
  /// is not there, and for a tag whose type is not a Label's.
  Future<void> assignLabel({
    required String habitId,
    required String userId,
    required String tagId,
  }) async {
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      final tag = await _requireTag(tagId);
      _requireLabelType(tag);
      await _insertHabitTag(habitId, tag.id, userId);
    });
  }

  /// Takes a Label off the Habit.
  ///
  /// The same rule as [assignLabel] holds here: a tag that is not a Label is
  /// refused, so an Area and a Label can never be quietly swapped for one
  /// another by writing through the wrong door.
  ///
  /// Throws an [ArgumentError] for a Habit that is not there, for a tag that
  /// is not there, and for a tag whose type is not a Label's.
  Future<void> unassignLabel({
    required String habitId,
    required String userId,
    required String tagId,
  }) async {
    await attachedDatabase.capturing(() async {
      await _requireHabit(habitId, userId);
      final tag = await _requireTag(tagId);
      _requireLabelType(tag);
      await (delete(habitTags)
            ..where((ht) => ht.habitId.equals(habitId) & ht.tagId.equals(tagId)))
          .go();
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

  /// The Check-ins of a Habit between [fromDay] and [toDay], both included.
  ///
  /// Oldest day first, and within a day oldest Check-in first.
  ///
  /// A range that ends before it starts is empty: there is no day in it.
  Future<List<HabitCheckIn>> checkInsFor(
    String habitId,
    String fromDay,
    String toDay,
  ) async {
    final from = _validatedDay(fromDay, 'fromDay');
    final to = _validatedDay(toDay, 'toDay');
    if (to.compareTo(from) < 0) return const [];
    return (select(habitCheckIns)
          ..where((c) =>
              c.habitId.equals(habitId) &
              c.countsForDay.isBiggerOrEqualValue(from) &
              c.countsForDay.isSmallerOrEqualValue(to))
          ..orderBy([
            (c) => OrderingTerm.asc(c.countsForDay),
            (c) => OrderingTerm.asc(c.checkedInAt),
            (c) => OrderingTerm.asc(c.id),
          ]))
        .get();
  }

  /// The paused and archived periods of a Habit, oldest first.
  Future<List<HabitInactivePeriod>> inactivePeriodsFor(String habitId) async =>
      (select(habitInactivePeriods)
            ..where((p) => p.habitId.equals(habitId))
            ..orderBy([
              (p) => OrderingTerm.asc(p.startsOn),
              (p) => OrderingTerm.asc(p.id),
            ]))
          .get();

  /// Everything the streak engine needs to know about one Habit, or null when
  /// there is no such Habit. A one-shot read.
  Future<HabitHistory?> habitHistory(String habitId) async {
    final habit = await habitById(habitId);
    if (habit == null) return null;
    return HabitHistory(
      habit: habit,
      commitments: await commitmentsFor(habitId),
      inactivePeriods: await inactivePeriodsFor(habitId),
      checkIns: await (select(habitCheckIns)
            ..where((c) => c.habitId.equals(habitId))
            ..orderBy([
              (c) => OrderingTerm.asc(c.countsForDay),
              (c) => OrderingTerm.asc(c.checkedInAt),
              (c) => OrderingTerm.asc(c.id),
            ]))
          .get(),
    );
  }

  /// Every Habit with its full history, oldest Habit first.
  ///
  /// Re-emits after a write to any of the four Habit tables: the Habits, their
  /// commitments, their Check-ins and their inactive periods.
  Stream<List<HabitHistory>> watchHabitHistories() {
    return customSelect(
      'SELECT id FROM habits ORDER BY created_at, id',
      readsFrom: {habits, habitCommitments, habitCheckIns, habitInactivePeriods},
    ).watch().asyncMap((rows) async {
      final histories = <HabitHistory>[];
      for (final row in rows) {
        final history = await habitHistory(row.read<String>('id'));
        if (history != null) histories.add(history);
      }
      return histories;
    });
  }

  /// The state of a Habit on [day].
  ///
  /// The state is derived from the Habit's dated periods, so this is a
  /// question about the rows and not a flag on the Habit: "was this Habit
  /// paused on Tuesday?" is answered the same way whatever the Habit's state
  /// is today.
  Future<HabitState> stateOn(String habitId, String day) async {
    final dayKey = _validatedDay(day, 'day');
    final periods = await _periodsFor(habitId);
    return _stateOf(periods, dayKey);
  }

  /// The Habits with the state each of them is in on [today], oldest first.
  ///
  /// The stream re-reads when a Habit or one of its periods changes, so a
  /// screen that shows the Habits of a day keeps up with a pause, an archive
  /// or a restore.
  ///
  /// [archived] narrows the list to the archived Habits (true) or to the
  /// ones that are not archived (false); left out, both are given.
  Stream<List<HabitWithState>> watchHabits(String today, {bool? archived}) {
    final day = _validatedDay(today, 'today');
    final query = select(habits).join([
      leftOuterJoin(
        habitInactivePeriods,
        habitInactivePeriods.habitId.equalsExp(habits.id) &
            habitInactivePeriods.startsOn.isSmallerOrEqualValue(day) &
            (habitInactivePeriods.endsBefore.isNull() |
                habitInactivePeriods.endsBefore.isBiggerThanValue(day)),
      ),
    ]);
    query.orderBy([
      OrderingTerm(expression: habits.createdAt),
      OrderingTerm(expression: habits.id),
    ]);
    return query.watch().map((rows) {
      final habitsById = <String, Habit>{};
      final periodsByHabit = <String, List<HabitInactivePeriod>>{};
      for (final row in rows) {
        final habit = row.readTable(habits);
        habitsById.putIfAbsent(habit.id, () => habit);
        final period = row.readTableOrNull(habitInactivePeriods);
        if (period != null) {
          (periodsByHabit[habit.id] ??= <HabitInactivePeriod>[]).add(period);
        }
      }
      final result = <HabitWithState>[];
      for (final habit in habitsById.values) {
        final state = _stateOf(
            periodsByHabit[habit.id] ?? const <HabitInactivePeriod>[], day);
        if (archived != null && (state == HabitState.archived) != archived) {
          continue;
        }
        result.add(HabitWithState(habit: habit, state: state));
      }
      return result;
    });
  }

  /// The tags a Habit holds — its Area and its Labels — by name.
  ///
  /// The read joins `tags`, so a junction row whose tag is gone is not
  /// returned: a row pointing at nothing is not a tag the Habit holds. That
  /// is what makes a Tag deleted somewhere else invisible here rather than a
  /// dangling claim.
  Future<List<Tag>> tagsFor(String habitId) async {
    final query = select(habitTags).join([
      innerJoin(tags, tags.id.equalsExp(habitTags.tagId)),
    ])
      ..where(habitTags.habitId.equals(habitId));
    query.orderBy([
      OrderingTerm.asc(tags.name),
      OrderingTerm.asc(tags.id),
    ]);
    final rows = await query.get();
    return [for (final row in rows) row.readTable(tags)];
  }

  // --- internals ------------------------------------------------------------

  /// The tag with [tagId], or an [ArgumentError] when there is no such tag.
  Future<Tag> _requireTag(String tagId) async {
    final tag = await (select(tags)..where((t) => t.id.equals(tagId)))
        .getSingleOrNull();
    if (tag == null) {
      throw ArgumentError.value(tagId, 'tagId', 'There is no Tag with that id.');
    }
    return tag;
  }

  /// Refuses a tag that is not a Label.
  ///
  /// The same refusal [assignLabel] and [unassignLabel] both make, so a Label
  /// and an Area are never swapped for one another by writing through the
  /// wrong door.
  static void _requireLabelType(Tag tag) {
    if (!habitLabelTagTypes.contains(tag.type)) {
      throw ArgumentError.value(
          tag.id,
          'tagId',
          'A Habit takes a label or a context tag as a Label, not a '
              '${tag.type} tag.');
    }
  }

  /// Removes the Habit's Area row, and any row whose tag is gone.
  Future<void> _removeAreaRows(String habitId) async {
    final rows = await (select(habitTags)
          ..where((ht) => ht.habitId.equals(habitId)))
        .get();
    for (final row in rows) {
      final tag = await (select(tags)..where((t) => t.id.equals(row.tagId)))
          .getSingleOrNull();
      if (tag == null || tag.type == habitAreaTagType) {
        await (delete(habitTags)..where((ht) => ht.id.equals(row.id))).go();
      }
    }
  }

  /// Writes the junction row for the (habitId, tagId) pair.
  ///
  /// The id is derived from the pair, so writing the same pair twice lands on
  /// the same row instead of accumulating duplicates.
  Future<void> _insertHabitTag(
      String habitId, String tagId, String userId) async {
    await into(habitTags).insert(
      HabitTagsCompanion.insert(
        id: habitTagIdFor(habitId, tagId),
        habitId: habitId,
        tagId: tagId,
        userId: userId,
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

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
    final periods = await _periodsFor(habitId);
    return _stateOf(periods, dayKey) == HabitState.archived;
  }

  /// Stamps the Habit as edited.
  ///
  /// A pause, an archive and a restore change the Habit's own state, so the
  /// Habit is edited on that day as well as on the day its details or its
  /// rule changed.
  Future<void> _stampEdited(String habitId, DateTime instant) async {
    await (update(habits)..where((h) => h.id.equals(habitId))).write(
          HabitsCompanion(updatedAt: Value(encodeInstant(instant))),
        );
  }

  /// The periods of a Habit, whichever kind they are.
  Future<List<HabitInactivePeriod>> _periodsFor(String habitId) async =>
      (select(habitInactivePeriods)..where((p) => p.habitId.equals(habitId)))
          .get();

  /// The state a Habit is in on [dayKey], given the periods that cover it.
  ///
  /// An archived period wins over a paused one: a Habit that was archived
  /// on a day was archived on that day, whatever else was true of it.
  static HabitState _stateOf(
      List<HabitInactivePeriod> periods, String dayKey) {
    var paused = false;
    for (final period in periods) {
      if (!_coversDay(period, dayKey)) continue;
      if (period.kind == _archivedKind) return HabitState.archived;
      if (period.kind == _pausedKind) paused = true;
    }
    return paused ? HabitState.paused : HabitState.active;
  }

  /// Whether a period covers a day.
  ///
  /// A period covers a day when it starts on or before that day and has not
  /// ended before it — `ends_before` is the first day the Habit is active
  /// again, so the day it names is not part of the period.
  static bool _coversDay(HabitInactivePeriod period, String dayKey) {
    if (period.startsOn.compareTo(dayKey) > 0) return false;
    final endsBefore = period.endsBefore;
    if (endsBefore != null && dayKey.compareTo(endsBefore) >= 0) return false;
    return true;
  }

  /// Refuses a commitment that would re-judge existing Check-ins wrongly.
  ///
  /// A weekly or monthly commitment governs from the start of its period, so
  /// it can reach back to Check-ins already recorded. Those Check-ins must
  /// still fit the new rule: an amount where it is measurable, none where it
  /// is binary. Otherwise the change is refused, and the caller can choose a
  /// rule that fits.
  Future<void> _requireCheckInsStillMatch(String habitId,
      List<HabitCommitment> before, List<HabitCommitment> all,
      HabitCommitment added) async {
    final fromDay = habitDayKey(effectiveStartOf(added));
    final checkIns = await (select(habitCheckIns)
          ..where((c) =>
              c.habitId.equals(habitId) &
              c.countsForDay.isBiggerOrEqualValue(fromDay)))
        .get();
    for (final checkIn in checkIns) {
      final measurable =
          commitmentInForceOn(all, checkIn.countsForDay)?.isMeasurable ?? false;
      final unitBefore =
          commitmentInForceOn(before, checkIn.countsForDay)?.unitLabel;
      final unitAfter =
          commitmentInForceOn(all, checkIn.countsForDay)?.unitLabel;
      // An amount is only a number: 10 pages must not turn into 10 minutes.
      if (checkIn.measuredAmount != null && unitBefore != unitAfter) {
        throw ArgumentError.value(
            added.chosenOn,
            'commitment',
            'This commitment starts on $fromDay, and the Check-in on '
                '${checkIn.countsForDay} was measured in another unit.');
      }
      if (measurable != (checkIn.measuredAmount != null)) {
        throw ArgumentError.value(
            added.chosenOn,
            'commitment',
            'This commitment starts on $fromDay, and the Check-in on '
                '${checkIn.countsForDay} does not fit it.');
      }
    }
  }

  /// Ends every pause that covers [day] at [day], whether it is open or has
  /// an end date still ahead. Days before [day] stay paused.
  Future<void> _closePauseCovering(String habitId, String day) async {
    await (update(habitInactivePeriods)..where((p) =>
            p.habitId.equals(habitId) &
            p.kind.equals(_pausedKind) &
            p.startsOn.isSmallerOrEqualValue(day) &
            (p.endsBefore.isNull() | p.endsBefore.isBiggerThanValue(day))))
        .write(HabitInactivePeriodsCompanion(endsBefore: Value(day)));
  }

  /// The Check-in with [checkInId], or an [ArgumentError] when there is no
  /// such Check-in or it belongs to another user.
  Future<HabitCheckIn> _requireCheckIn(String checkInId, String userId) async {
    final row = await (select(habitCheckIns)..where((c) => c.id.equals(checkInId)))
        .getSingleOrNull();
    if (row == null) {
      throw ArgumentError.value(
          checkInId, 'checkInId', 'There is no Check-in with that id.');
    }
    if (row.userId != userId) {
      throw ArgumentError.value(
          checkInId, 'checkInId', 'The Check-in belongs to another user.');
    }
    return row;
  }

  /// Whether the Habit is measured against a target on [dayKey].
  ///
  /// The rule is the commitment in force on that day, so a Habit that
  /// changes its target is binary before the change and measurable after it.
  /// A day before the first commitment has no rule, and is binary.
  Future<bool> _isMeasurableOn(String habitId, String dayKey) async {
    final commitment =
        commitmentInForceOn(await commitmentsFor(habitId), dayKey);
    return commitment?.isMeasurable ?? false;
  }

  /// Holds a Check-in's amount to the rule the Habit is judged by on that
  /// day.
  ///
  /// A measurable Habit needs an amount — "5 of 20 pages" is not a
  /// Check-in — and a binary one refuses one.
  Future<void> _requireAmountMatches(
      String habitId, String dayKey, double? amount) async {
    final measurable = await _isMeasurableOn(habitId, dayKey);
    if (measurable && amount == null) {
      throw ArgumentError.value(amount, 'measuredAmount',
          'This Habit is measured against a target, so its Check-in needs an amount.');
    }
    if (!measurable && amount != null) {
      throw ArgumentError.value(amount, 'measuredAmount',
          'This Habit is binary, so its Check-in has no amount.');
    }
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

  /// A day, checked: a local calendar day, `YYYY-MM-DD`.
  ///
  /// A day is the unit the whole Habit model is written in — a Check-in
  /// counts for one, a period covers them — so a day that is not a day is
  /// refused before it reaches the store.
  static String _validatedDay(String dayKey, String name) {
    if (habitDateFromDayKey(dayKey) == null) {
      throw ArgumentError.value(
          dayKey, name, 'A day is a local calendar day (YYYY-MM-DD).');
    }
    return dayKey;
  }

  /// How much was done, checked: null, or more than zero.
  ///
  /// Zero is not an amount — it says nothing was done, which is the absence
  /// of a Check-in and not a Check-in of nothing.
  static double? _validatedAmount(double? amount) {
    if (amount == null) return null;
    if (!amount.isFinite || amount <= 0) {
      throw ArgumentError.value(
          amount, 'measuredAmount', 'An amount is more than zero.');
    }
    return amount;
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
