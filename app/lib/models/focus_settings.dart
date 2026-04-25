/// User-configurable settings for Focus Mode (Pomodoro sprint timer).
class FocusSettings {
  const FocusSettings({
    this.sprintDurationMinutes = 20,
    this.breakDurationMinutes = 3,
  });

  final int sprintDurationMinutes;
  final int breakDurationMinutes;

  FocusSettings copyWith({
    int? sprintDurationMinutes,
    int? breakDurationMinutes,
  }) =>
      FocusSettings(
        sprintDurationMinutes:
            sprintDurationMinutes ?? this.sprintDurationMinutes,
        breakDurationMinutes: breakDurationMinutes ?? this.breakDurationMinutes,
      );
}
