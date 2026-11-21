/// Every word the Habit screens show that a person wrote rather than the
/// data: the empty states and the flash-banner lines. One file, so the final
/// lines from the design are a one-file change.
library;

import '../../models/habit_progress.dart' show HabitUnitKind;

/// Which flash banner is showing.
enum HabitFlash { created, paused, archived, anchorStopped, streakBroken }

/// A banner's Jeeves line and the facts beneath it.
class HabitFlashText {
  const HabitFlashText(this.line, this.facts);
  final String line;
  final String facts;
}

const _lines = <HabitFlash, List<String>>{
  HabitFlash.created: [
    'A new Habit, noted. Do begin.',
    'Very good. One more thing to be steady at.',
  ],
  HabitFlash.paused: [
    'Paused. It will keep, I assure you.',
    'Resting, then. Nothing is lost.',
  ],
  HabitFlash.archived: [
    'Archived. Its record stays in the drawer.',
    'Put away, not thrown out.',
  ],
  HabitFlash.anchorStopped: [
    'The Habit this one follows has stopped.',
    'This Habit has lost its anchor, I am afraid.',
  ],
  HabitFlash.streakBroken: [
    'The streak has broken. Begin again, sir.',
    'A miss. It happens to the best of us.',
  ],
};

/// The text of [flash]. [seed] rotates the pool; [facts] are the specifics.
HabitFlashText habitFlashText(HabitFlash flash, int seed, String facts) {
  final pool = _lines[flash]!;
  return HabitFlashText(pool[seed.abs() % pool.length], facts);
}

const habitsEmptyTitle = 'No Habits yet';
const habitsEmptyLine =
    'Things done regularly belong here. Shall we add the first?';
const habitsOnlyInactiveLine =
    'Every Habit is paused or archived. Resume one, or add a new Habit.';
const habitsAllDoneLine = 'All done for today.';
const habitsNothingDueLine = 'Nothing is due today.';
const habitsAddLabel = 'Add a Habit';
const habitsDetailPlaceholder = 'Choose a Habit to see its detail.';
const habitTitleEmptyMessage = 'A Habit needs a name.';

// ---- Check-in calendar ----

const habitCalendarTitle = 'Check-ins';
const habitCalendarOverline = 'HABIT';
const habitCalendarPreviousMonth = 'Previous month';
const habitCalendarNextMonth = 'Next month';
const habitCalendarPreviousYear = 'Previous year';
const habitCalendarNextYear = 'Next year';
const habitCalendarShowYear = 'Show the year';
const habitCalendarShowMonth = 'Show the month';
const habitCalendarRepeatChangedNote =
    'Repeat changed. Earlier days keep the old rule.';
const habitCalendarNoHabit = 'This Habit is not here any more.';

/// The legend under the month grid, in this order.
enum HabitCalendarLegendItem {
  checkIn('Check-in'),
  noCheckIn('No Check-in'),
  notDue('Not due'),
  paused('Paused'),
  beforeHabit('Before the Habit'),
  repeatChanged('Repeat changed');

  const HabitCalendarLegendItem(this.label);
  final String label;
}

/// A count mark: "2×", number first.
String habitCheckInCountMark(int count) => '$count×';

/// "5 of 8" for a measurable day.
String habitDayAmountText(double total, double target) =>
    '${habitAmountText(total)} of ${habitAmountText(target)}';

/// An amount without a trailing ".0".
String habitAmountText(double amount) => amount == amount.roundToDouble()
    ? amount.round().toString()
    : amount.toString();

/// The state words of a day's screen-reader label.
String habitDayStateWords(String state) => switch (state) {
  'done' => 'done',
  'partial' => 'partly done',
  'missed' => 'missed',
  'openToday' => 'not done yet',
  'notDue' => 'not due',
  'paused' => 'paused',
  'archived' => 'archived',
  'beforeHabit' => 'before the Habit',
  _ => 'not yet',
};

String habitCheckInCountWords(int count) =>
    count == 1 ? '1 Check-in' : '$count Check-ins';

const habitDayNotCountedPaused = 'not counted, paused';
const habitDayNotCountedArchived = 'not counted, archived';
const habitDayNotCountedRestDay = 'not counted, rest day';
const habitDayRepeatChangedWords = 'repeat changed';
const habitDayToday = 'today';

// ---- Stats block and history strip on the detail ----

/// The streak label under the main number.
String habitStreakLabel(HabitUnitKind kind) => switch (kind) {
  HabitUnitKind.day => 'day streak',
  HabitUnitKind.week => 'week streak',
  HabitUnitKind.month => 'month streak',
};

const habitBestStreakLabel = 'best streak';

/// "1 of 3 this week" / "1 of 4 this month", for an open period.
String habitPeriodProgressText(HabitUnitKind kind, int count, int target) =>
    '$count of $target this ${kind == HabitUnitKind.week ? 'week' : 'month'}';

/// A rate as a whole percent, or "—" when the window has nothing to count.
String habitRateText(double? value) =>
    value == null ? '—' : '${(value * 100).round()}%';

/// The tile labels of the three rate windows: the first reads "rate · …".
List<String> habitRateTileLabels(HabitUnitKind kind, List<int> lengths) {
  final unit = switch (kind) {
    HabitUnitKind.day => 'day',
    HabitUnitKind.week => 'week',
    HabitUnitKind.month => 'month',
  };
  return [
    for (var i = 0; i < lengths.length; i++)
      '${i == 0 ? 'rate · ' : ''}${lengths[i]} $unit${lengths[i] == 1 ? '' : 's'}',
  ];
}

/// The strip's one screen-reader label.
String habitHistoryStripLabel(int checkInDays, int dueDays) =>
    'Check-ins over the last five months: $checkInDays on $dueDays due days. '
    'Open the calendar';
