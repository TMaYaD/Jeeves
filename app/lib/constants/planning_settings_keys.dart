/// Shared SharedPreferences keys for planning-time settings.
///
/// Declared here so [daily_planning_provider.dart], [planning_settings_provider.dart],
/// and [daily_state_refresher.dart] all read and write the same keys without
/// creating a circular import.
const kSettingsTimeHour = 'planning_settings_time_hour';
const kSettingsTimeMinute = 'planning_settings_time_minute';
const kSettingsNotificationEnabled = 'planning_settings_notification_enabled';
