/// SharedPreferences keys for planning-time settings.
///
/// Declared here so [focus_session_planning_provider.dart],
/// [focus_session_planning_settings_provider.dart],
/// and [daily_state_refresher.dart] all read and write the same keys without
/// creating a circular import.
const kSettingsTimeHour = 'focus_session_planning_settings_time_hour';
const kSettingsTimeMinute = 'focus_session_planning_settings_time_minute';
const kSettingsNotificationEnabled =
    'focus_session_planning_settings_notification_enabled';
