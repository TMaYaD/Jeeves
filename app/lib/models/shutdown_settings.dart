import 'package:flutter/material.dart';

/// User-configurable settings for the Evening Shutdown feature.
class ShutdownSettings {
  const ShutdownSettings({
    this.shutdownTime = const TimeOfDay(hour: 18, minute: 0),
    this.notificationEnabled = true,
    this.bannerEnabled = true,
  });

  final TimeOfDay shutdownTime;
  final bool notificationEnabled;
  final bool bannerEnabled;

  ShutdownSettings copyWith({
    TimeOfDay? shutdownTime,
    bool? notificationEnabled,
    bool? bannerEnabled,
  }) =>
      ShutdownSettings(
        shutdownTime: shutdownTime ?? this.shutdownTime,
        notificationEnabled: notificationEnabled ?? this.notificationEnabled,
        bannerEnabled: bannerEnabled ?? this.bannerEnabled,
      );
}
