import 'package:flutter/material.dart';

/// User-configurable settings for the Focus Session Planning feature.
class FocusSessionPlanningSettings {
  const FocusSessionPlanningSettings({
    this.planningTime = const TimeOfDay(hour: 8, minute: 0),
    this.notificationEnabled = true,
    this.bannerEnabled = true,
    this.defaultSnoozeDuration = 60,
    this.snoozeDurations = const [15, 60, 1440],
  });

  final TimeOfDay planningTime;
  final bool notificationEnabled;
  final bool bannerEnabled;

  /// Default snooze duration in minutes.
  final int defaultSnoozeDuration;

  /// Available snooze durations in minutes (15 min, 1 hr, tomorrow).
  final List<int> snoozeDurations;

  FocusSessionPlanningSettings copyWith({
    TimeOfDay? planningTime,
    bool? notificationEnabled,
    bool? bannerEnabled,
    int? defaultSnoozeDuration,
    List<int>? snoozeDurations,
  }) =>
      FocusSessionPlanningSettings(
        planningTime: planningTime ?? this.planningTime,
        notificationEnabled: notificationEnabled ?? this.notificationEnabled,
        bannerEnabled: bannerEnabled ?? this.bannerEnabled,
        defaultSnoozeDuration:
            defaultSnoozeDuration ?? this.defaultSnoozeDuration,
        snoozeDurations: snoozeDurations ?? this.snoozeDurations,
      );
}
