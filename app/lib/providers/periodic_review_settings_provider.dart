/// Settings notifier and derived providers for the Weekly Review ceremony
/// (issue #54).
///
/// Storage-side keys live under the `periodic_review_*` namespace; user-
/// visible copy uses "Weekly Review". Cadence is hardcoded at 7 days; the
/// notification fires daily at the configured time and the banner's `isDue`
/// predicate gates relevance.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/notification_service.dart';
import 'focus_session_planning_provider.dart' show planningToday;
import 'synced_preferences_provider.dart';

const _kLastCompletedAtKey = 'periodic_review_last_completed_at';
const _kObjectivesKey = 'periodic_review_objectives';
const _kBannerDismissedDateKey = 'periodic_review_banner_dismissed_date';
const _kBannerEnabledKey = 'periodic_review_banner_enabled';
const _kNotificationEnabledKey = 'periodic_review_notification_enabled';
const _kNotificationHourKey = 'periodic_review_notification_hour';
const _kNotificationMinuteKey = 'periodic_review_notification_minute';
const _kNotificationSkippedDateKey =
    'periodic_review_notification_skipped_date';
const _kNotificationSnoozedUntilKey =
    'periodic_review_notification_snoozed_until';

const int _kCadenceDays = 7;

/// Returns today's date as a yyyy-MM-dd string in local time.
String _todayDateString() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

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
  final last = ref.watch(periodicReviewLastCompletedProvider);
  if (last == null) return true;
  return DateTime.now().difference(last).inDays >= _kCadenceDays;
});

/// True when the user has dismissed the banner today.
final periodicReviewBannerDismissedTodayProvider = Provider<bool>((ref) {
  final raw = ref
      .watch(syncedPreferencesProvider)
      .asData
      ?.value
      .get<String>(_kBannerDismissedDateKey);
  return raw == _todayDateString();
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

/// Last set of objectives, used to pre-populate Step 5 of the wizard.
final periodicReviewLastObjectivesProvider = Provider<List<String>>((ref) {
  final raw = ref
      .watch(syncedPreferencesProvider)
      .asData
      ?.value
      .get<String>(_kObjectivesKey);
  if (raw == null) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.whereType<String>().toList();
    }
  } catch (_) {
    // Stored value is malformed — surface as no prior objectives.
  }
  return const [];
});

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
        final today = planningToday();
        _periodicReviewNotificationSkippedToday =
            next.value.get<String>(_kNotificationSkippedDateKey) == today;
        _periodicReviewNotificationSnoozedActive = _parseSnoozedActive(
          next.value.get<String>(_kNotificationSnoozedUntilKey),
        );
        state = _fromPrefs(next.value);
        _rescheduleNotification();
      }
    });
    final current = ref.read(syncedPreferencesProvider).asData?.value;
    final initial = current != null ? _fromPrefs(current) : _defaults();
    // The listener above only fires on subsequent prefs changes, so kick off
    // an initial reschedule once the notifier is constructed.
    Future.microtask(_rescheduleNotification);
    return initial;
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

  Future<void> dismissBannerForToday() async {
    await syncedPrefs(ref).set(_kBannerDismissedDateKey, _todayDateString());
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

  Future<void> setObjectives(List<String> objectives) async {
    await syncedPrefs(ref).set(_kObjectivesKey, jsonEncode(objectives));
  }

  Future<void> _rescheduleNotification() async {
    final svc = ref.read(notificationServiceProvider);
    if (state.notificationEnabled &&
        !isPeriodicReviewNotificationSuppressedToday()) {
      await svc.schedulePeriodicReviewReminder(time: state.notificationTime);
    } else {
      await svc.cancelPeriodicReviewReminder();
    }
  }
}
