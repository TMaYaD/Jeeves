/// The repeat rule and the measurable target of a Habit, as one value.
///
/// A commitment is **append-only**: a change to a Habit's repeat rule or
/// target writes a new commitment and never rewrites an old one. A day is
/// then judged by *the commitment in force on that day* — the most recently
/// created commitment whose effective start is on or before it.
///
/// That is what keeps earlier periods honest: a change made on a Wednesday
/// governs the whole of that week, a change made on a Thursday to "every day"
/// governs from Thursday on and leaves Monday to Wednesday with the rule they
/// had, and a week or a month that has finished keeps the commitment it was
/// judged by.
///
/// The commitment is a code name, not a glossary term: the user chose a repeat
/// rule and a target, and the design pass called the record of that choice a
/// commitment.
library;

import 'dart:convert';

/// The day the week starts on: Monday.
///
/// A code constant, because only the day the user chose is stored. Changing
/// this later needs a migration of no rows.
const int habitWeekStartsOn = DateTime.monday;

/// The five repeat rules a Habit can carry, and the strings they are stored
/// as in `habit_commitments.repeat_kind`.
enum HabitRepeatKind {
  /// Every day.
  everyDay('every_day'),

  /// On the weekdays the user chose, ISO 1 = Monday … 7 = Sunday.
  chosenWeekdays('chosen_weekdays'),

  /// N times a week, with the chosen weekdays as a hint.
  timesPerWeek('times_per_week'),

  /// N times a month, with the chosen dates as a hint.
  timesPerMonth('times_per_month'),

  /// Every N days.
  everyNDays('every_n_days');

  const HabitRepeatKind(this.storedValue);

  /// The string this kind is stored as.
  final String storedValue;

  /// The kind stored as [storedValue], or null when the stored string is not
  /// one of the five.
  ///
  /// A read tolerates a row it does not recognise: a kind written by a later
  /// build is skipped, not a crash.
  static HabitRepeatKind? tryParse(String storedValue) {
    for (final kind in HabitRepeatKind.values) {
      if (kind.storedValue == storedValue) return kind;
    }
    return null;
  }
}

/// The repeat rule and the measurable target of a Habit.
///
/// The value validates itself: an invalid combination throws an
/// [ArgumentError] at construction, so an invalid commitment never reaches
/// the store.
class HabitCommitment {
  /// Builds a commitment, or throws an [ArgumentError] when the combination is
  /// not a rule the app accepts.
  factory HabitCommitment({
    required String id,
    required String habitId,
    required String chosenOn,
    required DateTime createdAt,
    required HabitRepeatKind repeatKind,
    List<int>? chosenWeekdays,
    int? timesPerPeriod,
    int? intervalDays,
    List<int>? preferredDays,
    String? unitLabel,
    double? dailyTargetAmount,
  }) {
    final weekdays =
        chosenWeekdays == null ? null : List<int>.unmodifiable(chosenWeekdays);
    final preferred =
        preferredDays == null ? null : List<int>.unmodifiable(preferredDays);
    _validate(
      id: id,
      habitId: habitId,
      chosenOn: chosenOn,
      repeatKind: repeatKind,
      chosenWeekdays: weekdays,
      timesPerPeriod: timesPerPeriod,
      intervalDays: intervalDays,
      preferredDays: preferred,
      unitLabel: unitLabel,
      dailyTargetAmount: dailyTargetAmount,
    );
    return HabitCommitment._(
      id: id,
      habitId: habitId,
      chosenOn: chosenOn,
      createdAt: createdAt,
      repeatKind: repeatKind,
      chosenWeekdays: weekdays,
      timesPerPeriod: timesPerPeriod,
      intervalDays: intervalDays,
      preferredDays: preferred,
      unitLabel: unitLabel,
      dailyTargetAmount: dailyTargetAmount,
    );
  }

  const HabitCommitment._({
    required this.id,
    required this.habitId,
    required this.chosenOn,
    required this.createdAt,
    required this.repeatKind,
    required this.chosenWeekdays,
    required this.timesPerPeriod,
    required this.intervalDays,
    required this.preferredDays,
    required this.unitLabel,
    required this.dailyTargetAmount,
  });

  /// The row's id, minted by the writer. The tie-break between two
  /// commitments written at the same instant.
  final String id;

  /// The Habit this commitment governs.
  final String habitId;

  /// The day the user made this commitment, a day key (`YYYY-MM-DD`).
  final String chosenOn;

  /// When the row was written (an instant).
  final DateTime createdAt;

  /// The repeat rule.
  final HabitRepeatKind repeatKind;

  /// The chosen weekdays, ISO 1 = Monday … 7 = Sunday. Set only for
  /// [HabitRepeatKind.chosenWeekdays].
  final List<int>? chosenWeekdays;

  /// N — how many times a week or a month. Set only for
  /// [HabitRepeatKind.timesPerWeek] and [HabitRepeatKind.timesPerMonth].
  final int? timesPerPeriod;

  /// The N of [HabitRepeatKind.everyNDays]. Set only for that kind.
  final int? intervalDays;

  /// A hint, not a rule: the days the user prefers. Weekdays 1–7 for a week,
  /// dates 1–31 for a month. Set only for [HabitRepeatKind.timesPerWeek] and
  /// [HabitRepeatKind.timesPerMonth].
  final List<int>? preferredDays;

  /// The unit the target is counted in ("pages", "glasses"). Null for a
  /// binary Habit.
  final String? unitLabel;

  /// How much of one period the target asks for. Set together with
  /// [unitLabel] for a measurable Habit, null for both on a binary one.
  final double? dailyTargetAmount;

  /// The chosen weekdays as canonical JSON, ready for
  /// `habit_commitments.chosen_weekdays`.
  String? get chosenWeekdaysJson =>
      chosenWeekdays == null ? null : canonicalDayListJson(chosenWeekdays!);

  /// The preferred days as canonical JSON, ready for
  /// `habit_commitments.preferred_days`.
  String? get preferredDaysJson =>
      preferredDays == null ? null : canonicalDayListJson(preferredDays!);

  /// Whether this Habit is measured against a target, rather than binary.
  bool get isMeasurable => dailyTargetAmount != null;

  static void _validate({
    required String id,
    required String habitId,
    required String chosenOn,
    required HabitRepeatKind repeatKind,
    required List<int>? chosenWeekdays,
    required int? timesPerPeriod,
    required int? intervalDays,
    required List<int>? preferredDays,
    required String? unitLabel,
    required double? dailyTargetAmount,
  }) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'A commitment needs an id.');
    }
    if (habitId.isEmpty) {
      throw ArgumentError.value(
          habitId, 'habitId', 'A commitment needs the Habit it governs.');
    }
    if (habitDateFromDayKey(chosenOn) == null) {
      throw ArgumentError.value(
          chosenOn, 'chosenOn', 'The chosen day must be a day key (YYYY-MM-DD).');
    }

    // The chosen weekdays belong to the one kind that uses them.
    if (repeatKind == HabitRepeatKind.chosenWeekdays) {
      if (chosenWeekdays == null || chosenWeekdays.isEmpty) {
        throw ArgumentError.value(chosenWeekdays, 'chosenWeekdays',
            'A chosen-weekdays commitment needs at least one weekday.');
      }
      for (final weekday in chosenWeekdays) {
        if (weekday < 1 || weekday > 7) {
          throw ArgumentError.value(weekday, 'chosenWeekdays',
              'A weekday is ISO 1 (Monday) to 7 (Sunday).');
        }
      }
    } else if (chosenWeekdays != null) {
      throw ArgumentError.value(chosenWeekdays, 'chosenWeekdays',
          'Only a chosen-weekdays commitment has chosen weekdays.');
    }

    // N is how many times a week or a month. It has no upper limit.
    if (repeatKind == HabitRepeatKind.timesPerWeek ||
        repeatKind == HabitRepeatKind.timesPerMonth) {
      if (timesPerPeriod == null) {
        throw ArgumentError.value(timesPerPeriod, 'timesPerPeriod',
            'A ${repeatKind.storedValue} commitment needs N.');
      }
      if (timesPerPeriod < 1) {
        throw ArgumentError.value(
            timesPerPeriod, 'timesPerPeriod', 'N is 1 or more.');
      }
    } else if (timesPerPeriod != null) {
      throw ArgumentError.value(timesPerPeriod, 'timesPerPeriod',
          'Only a per-week or per-month commitment has N.');
    }

    // The interval of "every N days".
    if (repeatKind == HabitRepeatKind.everyNDays) {
      if (intervalDays == null) {
        throw ArgumentError.value(intervalDays, 'intervalDays',
            'An every-N-days commitment needs its interval.');
      }
      if (intervalDays < 1) {
        throw ArgumentError.value(
            intervalDays, 'intervalDays', 'The interval is 1 day or more.');
      }
    } else if (intervalDays != null) {
      throw ArgumentError.value(intervalDays, 'intervalDays',
          'Only an every-N-days commitment has an interval.');
    }

    // The preferred days are a hint, and only the counted kinds have one.
    if (preferredDays != null) {
      if (repeatKind != HabitRepeatKind.timesPerWeek &&
          repeatKind != HabitRepeatKind.timesPerMonth) {
        throw ArgumentError.value(preferredDays, 'preferredDays',
            'Only a per-week or per-month commitment has preferred days.');
      }
      if (preferredDays.isEmpty) {
        throw ArgumentError.value(preferredDays, 'preferredDays',
            'An empty list of preferred days is no preference at all.');
      }
      final highest = repeatKind == HabitRepeatKind.timesPerWeek ? 7 : 31;
      final what = repeatKind == HabitRepeatKind.timesPerWeek
          ? 'a preferred weekday is ISO 1 (Monday) to 7 (Sunday)'
          : 'a preferred date is 1 to 31';
      for (final day in preferredDays) {
        if (day < 1 || day > highest) {
          throw ArgumentError.value(day, 'preferredDays', what);
        }
      }
    }

    // The unit and the target stand or fall together.
    if ((unitLabel == null) != (dailyTargetAmount == null)) {
      throw ArgumentError.value(
          unitLabel ?? dailyTargetAmount,
          unitLabel == null ? 'unitLabel' : 'dailyTargetAmount',
          'A measurable Habit has both a unit and a target; a binary Habit has neither.');
    }
    if (dailyTargetAmount != null &&
        !(dailyTargetAmount > 0 && dailyTargetAmount.isFinite)) {
      throw ArgumentError.value(dailyTargetAmount, 'dailyTargetAmount',
          'The target is a finite number more than zero.');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is HabitCommitment &&
      other.id == id &&
      other.habitId == habitId &&
      other.chosenOn == chosenOn &&
      other.createdAt == createdAt &&
      other.repeatKind == repeatKind &&
      _sameDays(other.chosenWeekdays, chosenWeekdays) &&
      other.timesPerPeriod == timesPerPeriod &&
      other.intervalDays == intervalDays &&
      _sameDays(other.preferredDays, preferredDays) &&
      other.unitLabel == unitLabel &&
      other.dailyTargetAmount == dailyTargetAmount;

  @override
  int get hashCode => Object.hash(
        id,
        habitId,
        chosenOn,
        createdAt,
        repeatKind,
        chosenWeekdays == null ? null : Object.hashAll(chosenWeekdays!),
        timesPerPeriod,
        intervalDays,
        preferredDays == null ? null : Object.hashAll(preferredDays!),
        unitLabel,
        dailyTargetAmount,
      );

  @override
  String toString() => 'HabitCommitment(${repeatKind.storedValue}, $chosenOn)';
}

bool _sameDays(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The canonical JSON of a list of days: sorted and deduplicated.
///
/// This is what `habit_commitments.chosen_weekdays` and
/// `habit_commitments.preferred_days` hold, so two commitments that mean the
/// same thing hold the same text.
String canonicalDayListJson(Iterable<int> days) {
  final sorted = days.toSet().toList()..sort();
  return jsonEncode(sorted);
}

/// The days in a canonical day list, or null when [json] is not one.
///
/// A read tolerates a text it does not recognise: null, and the row is
/// skipped rather than crashing the read.
List<int>? parseDayListJson(String? json) {
  if (json == null) return null;
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    final days = <int>[];
    for (final value in decoded) {
      if (value is! int) return null;
      days.add(value);
    }
    return List<int>.unmodifiable(days.toSet().toList()..sort());
  } on FormatException {
    return null;
  }
}

/// The day key of [date]: `YYYY-MM-DD`, the local calendar day.
String habitDayKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// The UTC calendar day of a day key, or null when [dayKey] is not `YYYY-MM-DD`.
DateTime? habitDateFromDayKey(String dayKey) {
  // Exactly ASCII digits: int.tryParse alone accepts "+1" and "-1", which
  // parse to a real date that would not round-trip to the key.
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dayKey)) return null;
  final parts = dayKey.split('-');
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > 31) return null;
  // UTC parts, so a day a time zone skipped (Pacific/Apia, 2011-12-30)
  // still parses.
  final date = DateTime.utc(year, month, day);
  // DateTime rolls an impossible date over (32 January is 1 February), so
  // check the parts survived.
  if (date.month != month || date.day != day) return null;
  return date;
}

/// The first day [commitment] governs.
///
/// - the day it was chosen, for the daily kinds;
/// - the Monday of that week, for a per-week commitment;
/// - the first day of that month, for a per-month commitment.
DateTime effectiveStartOf(HabitCommitment commitment) {
  final chosen = habitDateFromDayKey(commitment.chosenOn)!;
  switch (commitment.repeatKind) {
    case HabitRepeatKind.timesPerWeek:
      final offset = (chosen.weekday - habitWeekStartsOn + 7) % 7;
      // Calendar arithmetic, not elapsed time: a clock change inside the week
      // would otherwise land on the wrong day.
      final monday = DateTime.utc(chosen.year, chosen.month, chosen.day - offset);
      return DateTime.utc(monday.year, monday.month, monday.day);
    case HabitRepeatKind.timesPerMonth:
      return DateTime.utc(chosen.year, chosen.month);
    case HabitRepeatKind.everyDay:
    case HabitRepeatKind.chosenWeekdays:
    case HabitRepeatKind.everyNDays:
      return chosen;
  }
}

/// The first day each commitment governs, by commitment id.
///
/// [effectiveStartOf] says where a commitment's own period begins. This also
/// keeps a **finished** week or month with the commitment that governed it:
/// a per-week or per-month commitment never reaches back over a day whose
/// period (of the per-week or per-month commitment then in force) had already
/// ended when the new one was chosen. A change from "3 times a week" to "10
/// times a month" on 25 November leaves the week of 16–22 November judged by
/// the weekly rule, and the monthly rule governs from 23 November.
///
/// The daily kinds are judged a day at a time, so a new per-week or per-month
/// commitment still governs the days of its own period that came earlier.
Map<String, DateTime> effectiveStartsOf(List<HabitCommitment> commitments) {
  final ordered = [...commitments]
    ..sort((a, b) => _isLater(a, b) ? 1 : (_isLater(b, a) ? -1 : 0));
  final starts = <String, DateTime>{};
  for (var i = 0; i < ordered.length; i++) {
    final commitment = ordered[i];
    var start = effectiveStartOf(commitment);
    final chosen = habitDateFromDayKey(commitment.chosenOn)!;
    final countedKind =
        commitment.repeatKind == HabitRepeatKind.timesPerWeek ||
            commitment.repeatKind == HabitRepeatKind.timesPerMonth;
    if (countedKind) {
      // Walk the days the new commitment would reach back over, and lock the
      // ones that a finished period of an earlier commitment judged.
      var lockedThrough = start.subtract(const Duration(days: 1));
      for (var day = start;
          day.isBefore(chosen);
          day = DateTime.utc(day.year, day.month, day.day + 1)) {
        HabitCommitment? governing;
        for (var k = 0; k < i; k++) {
          final earlier = ordered[k];
          if (starts[earlier.id]!.isAfter(day)) continue;
          if (governing == null || _isLater(earlier, governing)) {
            governing = earlier;
          }
        }
        if (governing == null) continue;
        final periodEnd = _periodEndOf(governing, day);
        if (periodEnd != null && periodEnd.isBefore(chosen)) lockedThrough = day;
      }
      if (!lockedThrough.isBefore(start)) {
        start = DateTime.utc(
            lockedThrough.year, lockedThrough.month, lockedThrough.day + 1);
      }
    }
    starts[commitment.id] = start;
  }
  return starts;
}

/// The last day of the period of [commitment] that holds [day], or null for a
/// kind that is judged a day at a time.
DateTime? _periodEndOf(HabitCommitment commitment, DateTime day) {
  switch (commitment.repeatKind) {
    case HabitRepeatKind.timesPerWeek:
      final offset = (day.weekday - habitWeekStartsOn + 7) % 7;
      return DateTime.utc(day.year, day.month, day.day - offset + 6);
    case HabitRepeatKind.timesPerMonth:
      return DateTime.utc(day.year, day.month + 1, 0);
    case HabitRepeatKind.everyDay:
    case HabitRepeatKind.chosenWeekdays:
    case HabitRepeatKind.everyNDays:
      return null;
  }
}

/// The commitment in force on [dayKey], or null when there is none yet.
///
/// A commitment governs a day when its effective start (see
/// [effectiveStartsOf]) is on or before that day. Among those, the most
/// recently created wins, with the id as the tie-break between two written at
/// the same instant.
///
/// The commitments are the ones of one Habit; the caller passes that Habit's
/// commitments.
HabitCommitment? commitmentInForceOn(
    List<HabitCommitment> commitments, String dayKey) {
  final day = habitDateFromDayKey(dayKey);
  if (day == null) return null;
  final starts = effectiveStartsOf(commitments);
  HabitCommitment? winner;
  for (final commitment in commitments) {
    if (starts[commitment.id]!.isAfter(day)) continue;
    if (winner == null || _isLater(commitment, winner)) winner = commitment;
  }
  return winner;
}

/// Whether [candidate] was written after [other] — by instant, then by id.
bool _isLater(HabitCommitment candidate, HabitCommitment other) {
  final byInstant = candidate.createdAt.compareTo(other.createdAt);
  if (byInstant != 0) return byInstant > 0;
  return candidate.id.compareTo(other.id) > 0;
}
