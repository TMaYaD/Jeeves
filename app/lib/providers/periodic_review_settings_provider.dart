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

import '../models/ritual.dart';
import '../services/notification_service.dart';
import 'clock_provider.dart';
import 'gtd_lists_provider.dart' show Capture, Todo;
import 'synced_preferences_provider.dart';
import 'system_trust_provider.dart' show weeklyReviewDueAtProvider;

const kPeriodicReviewOpenSinceKey = 'periodic_review_open_since';

const _kLastCompletedAtKey = 'periodic_review_last_completed_at';
const _kLastSessionFinishedAtKey = 'periodic_review_last_session_finished_at';
const _kBannerEnabledKey = 'periodic_review_banner_enabled';
const _kNotificationEnabledKey = 'periodic_review_notification_enabled';
const _kNotificationHourKey = 'periodic_review_notification_hour';
const _kNotificationMinuteKey = 'periodic_review_notification_minute';
const int _kCadenceDays = 7;

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

/// UTC timestamp of the last review session finished with Done, partial or
/// final, or null if none. Unlike the completion stamp it never closes the
/// review period; it only moves the Weekly Review's due date.
final periodicReviewLastSessionFinishedProvider = Provider<DateTime?>((ref) {
  final raw = ref
      .watch(syncedPreferencesProvider)
      .asData
      ?.value
      .get<String>(_kLastSessionFinishedAtKey);
  if (raw == null) return null;
  return DateTime.tryParse(raw);
});

/// The active review period, closed by completion or seven days after opening.
final periodicReviewOpenSinceProvider = Provider<DateTime?>((ref) {
  final raw = ref.watch(syncedPreferencesProvider).asData?.value
      .get<String>(kPeriodicReviewOpenSinceKey);
  final opened = raw == null ? null : DateTime.tryParse(raw);
  if (opened == null) return null;
  final completed = ref.watch(periodicReviewLastCompletedProvider);
  if (completed != null && !opened.isAfter(completed)) return null;
  final now = ref.watch(clockProvider)();
  final expires = opened.add(const Duration(days: _kCadenceDays));
  if (!now.isBefore(expires)) return null;
  final timer = Timer(expires.difference(now), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return opened;
});

/// True when the Weekly Review is due: [weeklyReviewDueAtProvider] has
/// passed. The Notification reads this; the Banner's Cadence Trigger reads the
/// same due instant. An open review period does not make the review due, so a
/// finished short session clears both until seven days after it.
final periodicReviewIsDueProvider = Provider<bool>((ref) {
  final due = ref.watch(weeklyReviewDueAtProvider);
  if (due == null) return false;
  final now = ref.watch(clockProvider)();
  if (!now.isBefore(due)) return true;
  // Not due yet — re-evaluate exactly when the due instant passes, so the
  // Nudge surfaces reactively the moment the review falls due rather than
  // waiting for an unrelated rebuild. One timer, cancelled on dispose.
  final timer = Timer(due.difference(now), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return false;
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
    final stamp = ref.read(clockProvider)().toUtc().toIso8601String();
    await syncedPrefs(ref).set(_kLastCompletedAtKey, stamp);
    await syncedPrefs(ref).set(_kLastSessionFinishedAtKey, stamp);
  }

  /// Stamps the current UTC timestamp as the last finished session. A partial
  /// session's Done calls this; it leaves the completion stamp, and so the
  /// open review period, alone.
  Future<void> markSessionFinished() async {
    await syncedPrefs(ref).set(
      _kLastSessionFinishedAtKey,
      ref.read(clockProvider)().toUtc().toIso8601String(),
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
    //   2. Due — arm the recurring reminder.
    //   3. Not due — drop the recurring; a pending snooze (if any) stays.
    final isDue = ref.read(periodicReviewIsDueProvider);
    if (!state.notificationEnabled) {
      await svc.cancelRitualReminder(RitualId.weeklyReview);
    } else if (isDue) {
      await svc.scheduleRitualReminder(
          RitualId.weeklyReview, state.notificationTime);
    } else {
      // Not due — drop the recurring, but leave a pending snooze alone.
      await svc.cancelRecurringRitualReminder(RitualId.weeklyReview);
    }
  }
}
