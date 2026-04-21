# Scratchpad

## Current Goal
- [x] Issue #119: Replace Daily Planner auto-activation with persistent banner + snoozable notification

## Next Goals
- Wire up iOS `DarwinNotificationActionCategory` for planning notification actions on iOS (currently only Android actions are fully registered)
- Implement cold-start deep-link from notification (call `NotificationService.getLaunchDetails()` and navigate to `/planning` if launched via planning notification)
- Request notification permissions proactively when user enables the notification toggle in Settings

## Blockers
- None

## Notes
- Banner is rendered inside `AppShell` which wraps `child` in a `Column`; the inner screens use their own `Scaffold` so the banner sits above each screen's own app bar.
- `flutter_timezone` and `timezone` packages added to pubspec.yaml.
- Notification schedule uses `matchDateTimeComponents: time` — OS reschedules daily automatically. Snooze cancels this and uses a one-off schedule.

## Last Spec Read
- 2026-04-21
