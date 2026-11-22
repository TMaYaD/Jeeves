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
