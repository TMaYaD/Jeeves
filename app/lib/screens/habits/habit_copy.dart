/// Every word the Habit screens show that a person wrote rather than the
/// data: the empty states and the flash-banner lines. One file, so the final
/// lines from the design are a one-file change.
library;

import '../../database/gtd_database.dart' show HabitCheckIn;
import '../../models/habit_commitment.dart';
import '../../models/habit_progress.dart';

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

// ---- Check-in wording: the row, the number column and the Today card --------

const habitNotYetLine = 'Not yet';
const habitPausedLine = 'Paused';
const habitNotDueLine = 'Not due today';

String habitMarkLabel({
  required String title,
  required bool isMeasurable,
  required bool isDone,
  bool onTodayCard = false,
}) {
  if (isMeasurable) return 'Add a Check-in for $title';
  if (isDone) {
    return onTodayCard
        ? 'Checked in today. Tap to undo'
        : '$title: checked in. Tap to undo';
  }
  return 'Check in: $title';
}

/// The label under the streak number, from today's commitment.
String habitStreakLabel(HabitCommitment? commitment) =>
    switch (commitment?.repeatKind) {
      HabitRepeatKind.everyDay => 'day streak',
      HabitRepeatKind.timesPerWeek => 'week streak',
      HabitRepeatKind.timesPerMonth => 'month streak',
      _ => 'streak',
    };

/// "2 of 3 this week" for an N-a-week or N-a-month Habit, else null.
String? habitPeriodLine(HabitProgress progress, HabitCommitment? commitment) {
  final count = progress.periodCount;
  final target = progress.periodTarget;
  if (count == null || target == null) return null;
  final span =
      commitment?.repeatKind == HabitRepeatKind.timesPerMonth ? 'month' : 'week';
  return '$count of $target this $span';
}

/// Whether an N-a-week or N-a-month Habit has reached N and asks no more today.
bool habitPeriodComplete(HabitProgress progress) =>
    progress.todayState == HabitTodayState.notDue &&
    progress.periodTarget != null &&
    (progress.periodCount ?? 0) >= progress.periodTarget!;

String habitPeriodCompleteLine(HabitCommitment? commitment) =>
    commitment?.repeatKind == HabitRepeatKind.timesPerMonth
        ? 'Complete for this month'
        : 'Complete for this week';

/// An amount with thousands separators and no needless decimals.
String habitAmountText(double amount) {
  // Six places absorb float noise (0.7 + 0.1); trailing zeros are dropped.
  final rounded = double.parse(amount.toStringAsFixed(6));
  final whole = rounded == rounded.roundToDouble();
  final text = whole
      ? rounded.round().toString()
      : rounded
          .toStringAsFixed(6)
          .replaceFirst(RegExp(r'0+$'), '');
  final parts = text.split('.');
  final digits = parts.first;
  final negative = digits.startsWith('-');
  final body = negative ? digits.substring(1) : digits;
  final grouped = StringBuffer();
  for (var i = 0; i < body.length; i++) {
    if (i > 0 && (body.length - i) % 3 == 0) grouped.write(',');
    grouped.write(body[i]);
  }
  return '${negative ? '-' : ''}$grouped${parts.length > 1 ? '.${parts[1]}' : ''}';
}

/// "5 of 8 glasses".
String habitAmountLine(HabitProgress progress) =>
    '${habitAmountText(progress.todayTotalAmount ?? 0)} of '
    '${habitAmountText(progress.targetAmount ?? 0)} ${progress.unitLabel ?? ''}'
        .trimRight();

/// Pips show only for a whole target of 10 or less.
bool habitShowsPips(double? target) =>
    target != null && target == target.roundToDouble() && target >= 1 && target <= 10;

/// "07:34", local time, of a Check-in.
String habitCheckInClock(HabitCheckIn checkIn) {
  final local = DateTime.parse(checkIn.checkedInAt).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

/// The state part of the row's second line, or null.
String? habitRowStateText({
  required HabitProgress progress,
  required HabitCommitment? commitment,
  required List<HabitCheckIn> todaysCheckIns,
}) {
  switch (progress.todayState) {
    case HabitTodayState.paused:
      return null;
    case HabitTodayState.notDue:
      return habitPeriodComplete(progress)
          ? habitPeriodCompleteLine(commitment)
          : null;
    case HabitTodayState.done:
    case HabitTodayState.notYet:
      if (commitment?.isMeasurable ?? false) return habitAmountLine(progress);
      if (progress.todayState == HabitTodayState.notYet) return habitNotYetLine;
      return todaysCheckIns.isEmpty
          ? null
          : 'Done ${habitCheckInClock(todaysCheckIns.last)}';
  }
}

/// The Place in front of a Habit's own line: "Home · Not yet", or the Place
/// alone when the Habit has nothing else to say.
///
/// A Habit with no Place leaves the line as it was. A Place is shown wherever
/// the Habit appears, whether or not the user is there.
String habitPlaceLine({required String? placeName, required String? line}) {
  final place = placeName?.trim();
  final rest = line?.trim();
  if (place == null || place.isEmpty) return rest ?? '';
  if (rest == null || rest.isEmpty) return place;
  return '$place · $rest';
}

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Wed 18 Nov".
String habitTodayDateText(DateTime day) =>
    '${_weekdayNames[day.weekday - 1]} ${day.day} ${_monthNames[day.month - 1]}';

/// The Today card's state line.
String habitTodayCardState({
  required HabitProgress progress,
  required HabitCommitment? commitment,
  required List<HabitCheckIn> todaysCheckIns,
}) {
  final period = habitPeriodLine(progress, commitment);
  if (progress.todayState == HabitTodayState.paused) return habitPausedLine;
  if (progress.todayState == HabitTodayState.notDue) {
    return habitPeriodComplete(progress)
        ? habitPeriodCompleteLine(commitment)
        : habitNotDueLine;
  }
  if (commitment?.isMeasurable ?? false) {
    final n = todaysCheckIns.length;
    return '${habitAmountLine(progress)} · $n ${n == 1 ? 'entry' : 'entries'}';
  }
  if (progress.todayState == HabitTodayState.done && todaysCheckIns.isNotEmpty) {
    return 'Done ${habitCheckInClock(todaysCheckIns.last)} · tap the mark to undo';
  }
  if (habitPeriodComplete(progress)) return habitPeriodCompleteLine(commitment);
  if (progress.todayState == HabitTodayState.notYet && period != null) {
    return '$habitNotYetLine · $period';
  }
  return habitNotYetLine;
}

// ---- The measurable entry sheet ---------------------------------------------

const habitSheetOverline = 'HABIT · CHECK-IN';
const habitSheetDoneLabel = 'Done';
const habitSheetAddLabel = 'Add';
const habitSheetLessLabel = 'Less';
const habitSheetMoreLabel = 'More';
const habitSheetChangeLabel = 'Change this value';
const habitSheetRemoveLabel = 'Remove this Check-in';
const habitSheetTargetReachedLine = 'Target reached';
const habitSheetQuickAmounts = [2, 4];

/// "Today · Wed 18 Nov · each entry adds to the day".
String habitSheetDayLine(DateTime day) =>
    'Today · ${habitTodayDateText(day)} · each entry adds to the day';

/// "of 8 glasses".
String habitSheetOfTargetLine(HabitProgress progress) =>
    'of ${habitAmountText(progress.targetAmount ?? 0)} '
            '${progress.unitLabel ?? ''}'
        .trimRight();

/// "3 to go" below the target, "2 over. It all counts." above it, and null at
/// it (the sheet shows [habitSheetTargetReachedLine] there).
String? habitSheetStatusLine(HabitProgress progress) {
  final total = progress.todayTotalAmount ?? 0;
  final target = progress.targetAmount ?? 0;
  if (total < target) return '${habitAmountText(target - total)} to go';
  if (total > target) {
    return '${habitAmountText(total - target)} over. It all counts.';
  }
  return null;
}

/// "3 glasses": the unit exactly as stored.
String habitEntryAmountText(double amount, String? unitLabel) =>
    '${habitAmountText(amount)} ${unitLabel ?? ''}'.trimRight();

// ---- Next-in-stack offer ----------------------------------------------------

const habitOfferLine = 'Next in the order, sir.';
const habitOfferAcceptLabel = 'Right ho';
const habitOfferDismissLabel = 'Not now';
const habitOfferNotYetLine = 'Next in this stack \u00b7 not yet today';

/// The row offer's sub-line: "Stretch is attended to. Shall I take the
/// glasses?" for a measurable offered Habit, else without the question.
String habitOfferSubLine({required String sourceTitle, String? offeredUnit}) =>
    offeredUnit == null
        ? '$sourceTitle is attended to.'
        : '$sourceTitle is attended to. Shall I take the $offeredUnit?';

/// The entry sheet card's title.
String habitOfferFollowsLine(String title) => '$title follows, sir.';

// --- Focus Mode on a Habit (canvas item 21) ---------------------------------

const habitFocusOverline = 'HABIT · FOCUS MODE';
const habitFocusNotInPlanChip = "Habit · not in Today's Plan";
const habitFocusStartTooltip = 'Start Focus Mode on this Habit';
const habitFocusResumeTooltip = 'Resume Focus Mode on this Habit';
const habitFocusStopLabel = 'Stop';
const habitFocusBreakLabel = 'Start a break';
const habitFocusNextSprintLabel = 'Start next sprint';

/// The estimate chip of the Focus screen: "10m", "1h 30m".
String habitFocusEstimateChip(int minutes) => habitFocusMinutesLabel(minutes);

/// "Focus · 20m" on the Today card; "Resume Focus · 20m" when a Focus is open.
String habitFocusEntryLabel(int estimateMinutes, {required bool resume}) =>
    '${resume ? 'Resume Focus' : 'Focus'} · '
    '${habitFocusMinutesLabel(estimateMinutes)}';

/// Minutes as the canvas writes them: "45m", "1h 30m", "2h".
String habitFocusMinutesLabel(int minutes) {
  if (minutes < 60) return '${minutes}m';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '${hours}h' : '${hours}h ${rest}m';
}

// --- "Add a check-in, sir?" at the end of a Focus (canvas item 21) ----------

const habitFocusCheckInTitle = 'Add a check-in, sir?';
const habitFocusCheckInYesLabel = 'Very good';
const habitFocusCheckInNotNowLabel = 'Not now';

/// The sheet's first line for a binary Habit.
String habitFocusCheckInBinaryLine(String title, int minutesLogged) =>
    '$title · ${minutesLogged}m logged to this Habit. '
    'Nothing is added unless you say so.';

/// The sheet's first line for a measurable Habit.
String habitFocusCheckInMeasurableLine(String title, int minutesLogged) =>
    '$title · ${minutesLogged}m logged to this Habit. '
    'Say how far you got.';

/// The stepper's label: "pages to add".
String habitFocusCheckInStepperLabel(String? unitLabel) =>
    '${unitLabel ?? 'Amount'} to add';

/// "6 of 20 so far today".
String habitFocusCheckInSoFarLine(double total, double target) =>
    '${habitAmountText(total)} of ${habitAmountText(target)} so far today';

// --- Daily Planning: the read-only habits card ---------------------------

const habitsTodayHeader = 'Habits today';

const habitsTodayFooter = 'Not part of the plan and not counted in capacity.';

/// How many Habits the card shows before "and n more".
const habitsTodayCardLimit = 8;

String habitsTodayDoneCount(int done, int total) => '$done of $total done';

/// "42 days", "1 day", "0 days" for a day-based Habit; "1 of 3 this week"
/// for N a week or month.
String habitPlanningNumber(HabitProgress progress, HabitCommitment? commitment) {
  final period = habitPeriodLine(progress, commitment);
  if (period != null) return period;
  final days = progress.currentStreak;
  return '$days ${days == 1 ? 'day' : 'days'}';
}

String habitsTodayAllDoneLine(int total) => 'All $total have their Check-in';

String habitsTodayLongestStreakLine(int days) => 'longest streak $days';

String habitsTodayMoreLine(int hiddenCount) =>
    'and $hiddenCount more · shown in Habits';

// ---- Evening Shutdown: the habit step ---------------------------------------

const habitShutdownStepTitle = 'Habits';
const habitShutdownAddLabel = 'Add';
const habitShutdownLoadErrorText = 'Could not load your Habits.';
const habitShutdownRetryLabel = 'Try again';
const habitShutdownForwardLabelHabitsOnly = 'Close the day';

const _habitShutdownLines = [
  'A few routines are still open, sir.',
  'Before the lamps go out: these have no mark yet.',
  'Shall we settle the day\'s habits?',
];

/// The Jeeves line above the open Habits. [closingDay] rotates the pool.
String habitShutdownLine(String closingDay) {
  final seed = closingDay.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
  return _habitShutdownLines[seed % _habitShutdownLines.length];
}

const _longWeekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _longMonthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "Closing Tuesday, 18 November": names the day when it is not today.
String habitShutdownClosingDayLine(DateTime day) =>
    'Closing ${_longWeekdayNames[day.weekday - 1]}, '
    '${day.day} ${_longMonthNames[day.month - 1]}';

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
String habitStatsStreakLabel(HabitUnitKind kind) => switch (kind) {
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
    'Check-ins over the last five months: $checkInDays '
    '${checkInDays == 1 ? 'day' : 'days'} with Check-ins; '
    '$dueDays due ${dueDays == 1 ? 'day' : 'days'}. Open the calendar';

// ---- Past-day sheet ----

const habitDaySheetAdd = 'Add a Check-in';
const habitDaySheetClose = 'Close';
const habitDaySheetDone = 'Done';
const habitDaySheetPausedLine =
    "This day's Check-ins do not change the streak.";
const habitDaySheetChangeTooltip = 'Change this value';
const habitDaySheetRemoveTooltip = 'Remove this Check-in';
const habitDaySheetAmountLabel = 'Amount';
const habitDaySheetAmountIncrease = 'More';
const habitDaySheetAmountDecrease = 'Less';

/// The sheet's date title: "Thursday 12 November".
String habitDaySheetTitle(DateTime day) => _dayTitle(day);

String _dayTitle(DateTime day) {
  const weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${weekdays[day.weekday - 1]} ${day.day} ${months[day.month - 1]}';
}

/// "Water · no Check-in on this day".
String habitDaySheetEmptyLine(String title) =>
    '$title · no Check-in on this day';

/// "Water · 8 of 8 glasses · 3 entries".
String habitDaySheetMeasurableLine(
  String title,
  double total,
  double target,
  String? unit,
  int entries,
) =>
    '$title · ${habitDayAmountText(total, target)}'
    '${unit == null ? '' : ' $unit'}'
    '${entries == 0 ? '' : ' · $entries ${entries == 1 ? 'entry' : 'entries'}'}';

/// "Water · 2 Check-ins" for a binary day with Check-ins.
String habitDaySheetBinaryLine(String title, int count) =>
    '$title · ${habitCheckInCountWords(count)}';

/// "A Check-in here counts for 17 November."
String habitDaySheetCountsNote(DateTime day) {
  final title = _dayTitle(day);
  return 'A Check-in here counts for ${title.substring(title.indexOf(' ') + 1)}.';
}
