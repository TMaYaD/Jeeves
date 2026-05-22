/// Settings notifier and derived providers for the Weekly Review ceremony
/// (issue #54).
///
/// Storage-side keys live under the `periodic_review_*` namespace; user-
/// visible copy uses "Weekly Review". Cadence is hardcoded at 7 days; the
/// notification fires daily at the configured time and the banner's `isDue`
/// predicate gates relevance.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/notification_service.dart';
import 'focus_session_planning_provider.dart' show planningToday;
import 'gtd_lists_provider.dart';
import 'onboarding_provider.dart';
import 'synced_preferences_provider.dart';

const _kLastCompletedAtKey = 'periodic_review_last_completed_at';
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

/// The "empty actionable" leg of the Weekly Review banner predicate:
/// true when inbox + next are both empty but waiting-for or maybe still
/// hold items. Extracted so both the Weekly Review Content-state Trigger
/// and [periodicReviewBannerVisibleProvider] share the same rule.
///
/// Stays as a pure function (over `AsyncValue`s) rather than as another
/// Provider so callers can keep the original short-circuit order — the
/// cheap `enabled` / `dismissed` / `hasTodos` watches must run before
/// the list watches subscribe `unfilteredInboxProvider` et al., which
/// pull in the full `databaseProvider` chain.
bool emptyActionableBannerTrigger({
  required AsyncValue<List<Todo>> inbox,
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

/// True when the Weekly Review banner would render. Used by the daily
/// focus-session-planning banner so it can yield the slot whenever the
/// weekly banner is taking it — the two never stack.
///
/// The cheap watches (`enabled`, `dismissed`, `hasTodos`) run before
/// the list watches so callers gated off via `enabled=false` never pay
/// the cost of subscribing to the database-backed list streams.
final periodicReviewBannerVisibleProvider = Provider<bool>((ref) {
  if (!ref.watch(periodicReviewBannerEnabledProvider)) return false;
  if (ref.watch(periodicReviewBannerDismissedTodayProvider)) return false;

  final hasTodos = ref.watch(hasTodosProvider);
  if (!hasTodos.hasValue || !hasTodos.requireValue) return false;

  if (ref.watch(periodicReviewIsDueProvider)) return true;

  return emptyActionableBannerTrigger(
    inbox: ref.watch(unfilteredInboxProvider),
    next: ref.watch(unfilteredNextActionsProvider),
    waiting: ref.watch(unfilteredWaitingForProvider),
    maybe: ref.watch(unfilteredMaybeProvider),
  );
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

  Future<void> _rescheduleNotification() async {
    final svc = ref.read(notificationServiceProvider);
    // Only arm the daily reminder while the review is actually due — firing
    // "Time for your Weekly Review" on a day the cadence has not elapsed
    // would lie to the user. The schedule is re-evaluated on every prefs
    // change (the listener in build()) so completion immediately disarms it
    // and the next cadence flip (driven by writes from any device, e.g.
    // `last_completed_at` aging out via cross-device sync, or any other
    // pref write while the app is alive) re-arms it.
    final isDue = ref.read(periodicReviewIsDueProvider);
    if (state.notificationEnabled &&
        isDue &&
        !isPeriodicReviewNotificationSuppressedToday()) {
      await svc.schedulePeriodicReviewReminder(time: state.notificationTime);
    } else if (_periodicReviewNotificationSnoozedActive) {
      // The user just tapped "Snooze". Don't kill their one-off snooze
      // fire just because the recurring schedule shouldn't run today —
      // only cancel the recurring id so the snooze can still fire on
      // its scheduled time. Once the snooze fires (or expires) the
      // module-level flag flips false and the next reschedule falls
      // through to the regular cancel-both branch.
      await svc.cancelPeriodicReviewRecurringReminder();
    } else {
      await svc.cancelPeriodicReviewReminder();
    }
  }
}
