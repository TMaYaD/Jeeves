/// Settings notifier and derived providers for the Weekly Review ceremony
/// (issue #54).
///
/// Storage-side keys live under the `periodic_review_*` namespace; user-
/// visible copy uses "Weekly Review". Cadence is hardcoded at 7 days; the
/// notification fires daily at the configured time and the banner's `isDue`
/// predicate gates relevance.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ritual.dart';
import '../services/notification_service.dart';
import 'clock_provider.dart';
import 'focus_session_planning_provider.dart' show planningToday;
import 'gtd_lists_provider.dart' show Capture, Todo;
import 'synced_preferences_provider.dart';

const _kLastCompletedAtKey = 'periodic_review_last_completed_at';
const _kBannerEnabledKey = 'periodic_review_banner_enabled';
const _kNotificationEnabledKey = 'periodic_review_notification_enabled';
const _kNotificationHourKey = 'periodic_review_notification_hour';
const _kNotificationMinuteKey = 'periodic_review_notification_minute';
const _kNotificationSkippedDateKey =
    'periodic_review_notification_skipped_date';
const _kNotificationSnoozedUntilKey =
    'periodic_review_notification_snoozed_until';

const int _kCadenceDays = 7;

// ---------------------------------------------------------------------------
// Notification suppression helpers
// ---------------------------------------------------------------------------

bool _periodicReviewNotificationSkippedToday = false;
bool _periodicReviewNotificationSnoozedActive = false;

bool _parseSnoozedActive(String? snoozedUntilStr) {
  if (snoozedUntilStr == null) return false;
  final snoozedUntil = DateTime.tryParse(snoozedUntilStr);
  return snoozedUntil != null && DateTime.now().isBefore(snoozedUntil);
}

/// Returns true if the user has skipped/snoozed the periodic-review
/// notification for today.
bool isPeriodicReviewNotificationSuppressedToday() =>
    _periodicReviewNotificationSkippedToday ||
    _periodicReviewNotificationSnoozedActive;

/// Returns true iff the user tapped "Skip today" (as distinct from an active
/// snooze). The reschedule logic uses this to suppress *today*'s recurring
/// fire while leaving tomorrow's intact; the snooze is satisfied by its own
/// one-off and does not need to touch the recurring schedule.
bool isPeriodicReviewNotificationSkippedToday() =>
    _periodicReviewNotificationSkippedToday;

/// Reads periodic-review skip/snooze state from [SharedPreferences] into
/// module-level flags. Call once on startup before scheduling.
Future<void> loadPeriodicReviewNotificationSuppression() async {
  final prefs = await SharedPreferences.getInstance();
  final today = planningToday();
  _periodicReviewNotificationSkippedToday =
      prefs.getString(_kNotificationSkippedDateKey) == today;
  _periodicReviewNotificationSnoozedActive = _parseSnoozedActive(
    prefs.getString(_kNotificationSnoozedUntilKey),
  );
}

/// Persists and activates the "skip periodic review today" suppression.
///
/// Dual-writes to SharedPreferences (startup reads) and synced preferences
/// (cross-device visibility). Pass [ref] to enable the Drift write.
Future<void> persistPeriodicReviewSkipToday({Ref? ref}) async {
  final today = planningToday();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kNotificationSkippedDateKey, today);
  _periodicReviewNotificationSkippedToday = true;
  if (ref != null) {
    await syncedPrefs(ref).set(_kNotificationSkippedDateKey, today);
  }
}

/// Persists and activates a periodic-review snooze until [until].
///
/// Dual-writes to SharedPreferences (startup reads) and synced preferences
/// (cross-device visibility). Pass [ref] to enable the Drift write.
Future<void> persistPeriodicReviewSnoozedUntil(DateTime until,
    {Ref? ref}) async {
  final value = until.toIso8601String();
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kNotificationSnoozedUntilKey, value);
  _periodicReviewNotificationSnoozedActive = DateTime.now().isBefore(until);
  if (ref != null) {
    await syncedPrefs(ref).set(_kNotificationSnoozedUntilKey, value);
  }
}

// ---------------------------------------------------------------------------
// Derived providers — read straight from synced preferences
// ---------------------------------------------------------------------------

/// UTC timestamp of the last Weekly Review completion, or null if never.
final periodicReviewLastCompletedProvider = Provider<DateTime?>((ref) {
  final raw = ref
      .watch(syncedPreferencesProvider)
      .asData
      ?.value
      .get<String>(_kLastCompletedAtKey);
  if (raw == null) return null;
  return DateTime.tryParse(raw);
});

/// True when the review is due (never completed, or > [_kCadenceDays] old).
final periodicReviewIsDueProvider = Provider<bool>((ref) {
  final now = ref.watch(clockProvider)();
  final last = ref.watch(periodicReviewLastCompletedProvider);
  if (last == null) return true;
  final due = last.add(const Duration(days: _kCadenceDays));
  if (now.isBefore(due)) {
    // Not due yet — re-evaluate exactly when the cadence boundary passes, so a
    // Weekly Review Nudge surfaces reactively the moment it becomes due rather
    // than waiting for an unrelated rebuild. One timer, cancelled on dispose.
    final timer = Timer(due.difference(now), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
    return false;
  }
  return true;
});

/// Whether the Weekly Review banner is enabled (defaults to true).
final periodicReviewBannerEnabledProvider = Provider<bool>((ref) {
  return ref
          .watch(syncedPreferencesProvider)
          .asData
          ?.value
          .get<bool>(_kBannerEnabledKey) ??
      true;
});

/// The "empty actionable" leg of the Weekly Review Content-state Trigger:
/// true when inbox + next are both empty but waiting-for or maybe still
/// hold items.
///
/// [inbox] holds Captures, not Outcomes — the Inbox is `captures` with
/// `clarified_at IS NULL` since the split (ADR-0006). Only emptiness is read,
/// so the two shapes are interchangeable here.
///
/// Stays as a pure function (over `AsyncValue`s) rather than a Provider
/// so callers can short-circuit cheap checks before subscribing the
/// list streams that pull in the full `databaseProvider` chain.
bool emptyActionableBannerTrigger({
  required AsyncValue<List<Capture>> inbox,
  required AsyncValue<List<Todo>> next,
  required AsyncValue<List<Todo>> waiting,
  required AsyncValue<List<Todo>> maybe,
}) {
  if (!inbox.hasValue ||
      !next.hasValue ||
      !waiting.hasValue ||
      !maybe.hasValue) {
    return false;
  }
  return inbox.requireValue.isEmpty &&
      next.requireValue.isEmpty &&
      (waiting.requireValue.isNotEmpty || maybe.requireValue.isNotEmpty);
}

// ---------------------------------------------------------------------------
// Settings notifier
// ---------------------------------------------------------------------------

/// Public view of Weekly Review settings.
class PeriodicReviewSettings {
  const PeriodicReviewSettings({
    required this.notificationEnabled,
    required this.bannerEnabled,
    required this.notificationTime,
  });

  final bool notificationEnabled;
  final bool bannerEnabled;
  final TimeOfDay notificationTime;

  PeriodicReviewSettings copyWith({
    bool? notificationEnabled,
    bool? bannerEnabled,
    TimeOfDay? notificationTime,
  }) =>
      PeriodicReviewSettings(
        notificationEnabled: notificationEnabled ?? this.notificationEnabled,
        bannerEnabled: bannerEnabled ?? this.bannerEnabled,
        notificationTime: notificationTime ?? this.notificationTime,
      );
}

final periodicReviewSettingsProvider =
    NotifierProvider<PeriodicReviewSettingsNotifier, PeriodicReviewSettings>(
  PeriodicReviewSettingsNotifier.new,
);

class PeriodicReviewSettingsNotifier
    extends Notifier<PeriodicReviewSettings> {
  @override
  PeriodicReviewSettings build() {
    ref.listen(syncedPreferencesProvider, (_, next) {
      if (next is AsyncData<SyncedPreferences>) {
        _refreshNotificationSuppression(next.value);
        state = _fromPrefs(next.value);
        _rescheduleNotification();
      }
    });
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    // Seed the suppression flags from the current snapshot before the
    // initial reschedule below; the listener above only fires on later
    // synced-prefs events, so without this the first reschedule would
    // see stale process defaults and ignore a persisted skip-today /
    // active snooze.
    if (current != null) {
      _refreshNotificationSuppression(current);
    } else {
      // No snapshot yet — reset suppression to defaults so the initial
      // reschedule below doesn't act on stale module-level globals left from a
      // prior provider lifecycle.
      _periodicReviewNotificationSkippedToday = false;
      _periodicReviewNotificationSnoozedActive = false;
    }
    final initial = current != null ? _fromPrefs(current) : _defaults();
    // The listener above only fires on subsequent prefs changes, so kick off
    // an initial reschedule once the notifier is constructed.
    Future.microtask(_rescheduleNotification);
    return initial;
  }

  void _refreshNotificationSuppression(SyncedPreferences prefs) {
    final today = planningToday();
    _periodicReviewNotificationSkippedToday =
        prefs.get<String>(_kNotificationSkippedDateKey) == today;
    _periodicReviewNotificationSnoozedActive = _parseSnoozedActive(
      prefs.get<String>(_kNotificationSnoozedUntilKey),
    );
  }

  static PeriodicReviewSettings _defaults() => const PeriodicReviewSettings(
        notificationEnabled: true,
        bannerEnabled: true,
        notificationTime: TimeOfDay(hour: 9, minute: 0),
      );

  PeriodicReviewSettings _fromPrefs(SyncedPreferences prefs) {
    final hour = prefs.get<int>(_kNotificationHourKey) ?? 9;
    final minute = prefs.get<int>(_kNotificationMinuteKey) ?? 0;
    return PeriodicReviewSettings(
      notificationEnabled: prefs.get<bool>(_kNotificationEnabledKey) ?? true,
      bannerEnabled: prefs.get<bool>(_kBannerEnabledKey) ?? true,
      notificationTime: TimeOfDay(hour: hour, minute: minute),
    );
  }

  /// Stamps the current UTC timestamp as the last completion. The cross-
  /// device LWW + tombstone semantics from synced-prefs ensure all devices
  /// suppress the banner on their next sync.
  Future<void> completeReview() async {
    await syncedPrefs(ref).set(
      _kLastCompletedAtKey,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> setBannerEnabled(bool enabled) async {
    await syncedPrefs(ref).set(_kBannerEnabledKey, enabled);
  }

  Future<void> setNotificationEnabled(bool enabled) async {
    await syncedPrefs(ref).set(_kNotificationEnabledKey, enabled);
  }

  Future<void> setNotificationTime(TimeOfDay time) async {
    await syncedPrefs(ref).set(_kNotificationHourKey, time.hour);
    await syncedPrefs(ref).set(_kNotificationMinuteKey, time.minute);
  }

  Future<void> _rescheduleNotification() async {
    final svc = ref.read(notificationServiceProvider);
    // Priority order:
    //   1. Notifications disabled — kill recurring and snooze ids together.
    //      Must come first so a still-active snooze cannot keep firing after
    //      the user turns notifications off.
    //   2. Skipped today — cancel today's snooze id only; the recurring
    //      schedule keeps firing tomorrow via matchDateTimeComponents.
    //   3. Due and not suppressed — arm the recurring reminder.
    //   4. Not due — drop the recurring; a pending snooze (if any) stays.
    final isDue = ref.read(periodicReviewIsDueProvider);
    if (!state.notificationEnabled) {
      await svc.cancelRitualReminder(RitualId.weeklyReview);
    } else if (isPeriodicReviewNotificationSkippedToday()) {
      await svc.skipTodayRitualReminder(RitualId.weeklyReview);
    } else if (isDue) {
      await svc.scheduleRitualReminder(
          RitualId.weeklyReview, state.notificationTime);
    } else {
      // Not due — drop the recurring, but leave a pending snooze alone.
      await svc.cancelRecurringRitualReminder(RitualId.weeklyReview);
    }
  }
}
