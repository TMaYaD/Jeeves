/// User-configurable settings for Focus Mode (Pomodoro sprint timer).
///
/// The lengths and counts of the Sprint/Break cadence. Every one of them
/// travels as its own `user_preferences` key, so the latest choice on any
/// device wins and a device that never set one reads the default.
library;

/// The default Sprint length, in minutes.
const int kDefaultSprintDurationMinutes = 20;

/// The default short Break length, in minutes.
const int kDefaultShortBreakDurationMinutes = 3;

/// The default long Break length, in minutes.
const int kDefaultLongBreakDurationMinutes = 15;

/// The default number of Sprints before a long Break.
const int kDefaultSprintsBeforeLongBreak = 4;

/// The `user_preferences` key the Sprint length is stored under.
const kFocusSprintDurationMinutesPrefKey =
    'focus_settings_sprint_duration_minutes';

/// The `user_preferences` key the short Break length is stored under.
///
/// The key predates the long Break and keeps its name: renaming it would drop
/// the length every user has already chosen.
const kFocusBreakDurationMinutesPrefKey =
    'focus_settings_break_duration_minutes';

/// The `user_preferences` key the long Break length is stored under.
const kFocusLongBreakDurationMinutesPrefKey =
    'focus_settings_long_break_duration_minutes';

/// The `user_preferences` key the number of Sprints before a long Break is
/// stored under.
const kFocusSprintsBeforeLongBreakPrefKey =
    'focus_settings_sprints_before_long_break';

class FocusSettings {
  const FocusSettings({
    this.sprintDurationMinutes = kDefaultSprintDurationMinutes,
    this.shortBreakDurationMinutes = kDefaultShortBreakDurationMinutes,
    this.longBreakDurationMinutes = kDefaultLongBreakDurationMinutes,
    this.sprintsBeforeLongBreak = kDefaultSprintsBeforeLongBreak,
  });

  final int sprintDurationMinutes;

  /// The short Break: the rest after every Sprint, long Break or not.
  final int shortBreakDurationMinutes;

  /// The long Break: the rest after a run of Sprints (issue #911).
  final int longBreakDurationMinutes;

  /// How many Sprints come before a long Break. The count runs across Actions.
  final int sprintsBeforeLongBreak;

  FocusSettings copyWith({
    int? sprintDurationMinutes,
    int? shortBreakDurationMinutes,
    int? longBreakDurationMinutes,
    int? sprintsBeforeLongBreak,
  }) =>
      FocusSettings(
        sprintDurationMinutes:
            sprintDurationMinutes ?? this.sprintDurationMinutes,
        shortBreakDurationMinutes:
            shortBreakDurationMinutes ?? this.shortBreakDurationMinutes,
        longBreakDurationMinutes:
            longBreakDurationMinutes ?? this.longBreakDurationMinutes,
        sprintsBeforeLongBreak:
            sprintsBeforeLongBreak ?? this.sprintsBeforeLongBreak,
      );
}
