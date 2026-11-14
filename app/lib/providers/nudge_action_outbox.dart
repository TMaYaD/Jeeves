/// Carries notification Skip / Snooze taps into the Nudge's dismiss / snooze
/// state.
///
/// A notification action button can run in a background isolate, which has no
/// Riverpod container and no database — only [SharedPreferences]. So the
/// handler appends what the user did, and when, to a device-local outbox
/// ([appendNudgeAction]); a main-isolate drainer ([nudgeActionOutboxDrainerProvider])
/// applies it through `NudgeActions` and clears it. The recorded action time,
/// not the drain time, is what `dismissed_at` stores, so an action drained
/// after a later refire never wrongly silences that refire.
///
/// The drainer also runs the one-time carry-over of live legacy
/// `*_notification_skipped_date` / `*_notification_snoozed_until` values into
/// the Nudge state. The legacy keys stay stored and inert; nothing is deleted.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ritual.dart';
import '../services/notification_service.dart'
    show RitualNotificationActionKind;
import 'clock_provider.dart';
import 'nudge_provider.dart';
import 'synced_preferences_provider.dart';

/// Device-local (not synced) SharedPreferences key prefix of the outbox. Each
/// pending action is its own entry, `<prefix><tap micros>.<random>`, holding one
/// JSON-encoded [PendingNudgeAction].
///
/// One key per action, never one shared list: SharedPreferences has no
/// cross-isolate lock, so a read-modify-write of a shared list loses whichever
/// write lands second. A unique key is only ever written once and removed by
/// the drainer that applied it, so appenders and the drainer cannot clobber
/// each other.
const kNudgeActionOutboxKeyPrefix = 'nudge_action_outbox.';

/// Device-local marker: set once the legacy suppression values have been
/// carried over to the Nudge state on this device.
const kNudgeLegacyMigrationMarkerKey = 'nudge_legacy_suppression_migrated';

enum NudgeActionVerb { dismiss, snooze }

/// One notification action the user took, waiting to be applied to Nudge state.
class PendingNudgeAction {
  const PendingNudgeAction({
    required this.ritual,
    required this.verb,
    required this.at,
    this.until,
  });

  final RitualId ritual;
  final NudgeActionVerb verb;

  /// When the user tapped the button.
  final DateTime at;

  /// Snooze expiry. Set for [NudgeActionVerb.snooze], null for dismiss.
  final DateTime? until;

  String toJson() => jsonEncode({
        'ritual': ritual.keyPrefix,
        'verb': verb.name,
        'at': at.toUtc().toIso8601String(),
        if (until != null) 'until': until!.toUtc().toIso8601String(),
      });

  /// Returns null for an entry that cannot be read (corrupt or from a build
  /// that knew other Rituals) so one bad entry cannot wedge the outbox.
  static PendingNudgeAction? tryParse(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final ritual = RitualId.values
          .where((r) => r.keyPrefix == m['ritual'])
          .firstOrNull;
      final verb = NudgeActionVerb.values
          .where((v) => v.name == m['verb'])
          .firstOrNull;
      final at = DateTime.tryParse(m['at'] as String? ?? '');
      final until = DateTime.tryParse(m['until'] as String? ?? '');
      if (ritual == null || verb == null || at == null) return null;
      if (verb == NudgeActionVerb.snooze && until == null) return null;
      return PendingNudgeAction(
          ritual: ritual, verb: verb, at: at, until: until);
    } catch (_) {
      return null;
    }
  }
}

/// Bumped whenever this isolate appends to the outbox, so the drainer can run
/// right after a foreground notification response. A background isolate has
/// its own copy that nothing listens to; the drainer picks those entries up
/// on the next app resume instead.
final ValueNotifier<int> nudgeActionOutboxChanged = ValueNotifier<int>(0);

final _outboxKeyRandom = Random();

/// Appends [action] to the outbox. Safe to call from a background isolate:
/// it writes one fresh key and reads nothing back.
Future<void> appendNudgeAction(PendingNudgeAction action) async {
  final prefs = await SharedPreferences.getInstance();
  final key = '$kNudgeActionOutboxKeyPrefix'
      '${action.at.toUtc().microsecondsSinceEpoch.toString().padLeft(20, '0')}.'
      '${_outboxKeyRandom.nextInt(1 << 32).toRadixString(16)}';
  await prefs.setString(key, action.toJson());
  nudgeActionOutboxChanged.value++;
}

/// Records a Skip or Snooze tap on [ritual]'s notification: Skip is a dismiss
/// at [at]; Snooze hides the Nudge until [at] + [snoozeMinutes]. [open] is not
/// recorded — opening is routing, not a Nudge action.
Future<void> recordRitualNotificationAction({
  required RitualId ritual,
  required RitualNotificationActionKind kind,
  required DateTime at,
  required int snoozeMinutes,
}) async {
  switch (kind) {
    case RitualNotificationActionKind.open:
      return;
    case RitualNotificationActionKind.skip:
      await appendNudgeAction(PendingNudgeAction(
          ritual: ritual, verb: NudgeActionVerb.dismiss, at: at));
    case RitualNotificationActionKind.snooze:
      await appendNudgeAction(PendingNudgeAction(
        ritual: ritual,
        verb: NudgeActionVerb.snooze,
        at: at,
        until: at.add(Duration(minutes: snoozeMinutes)),
      ));
  }
}

/// Applies every outboxed action through `NudgeActions`, oldest first, and
/// removes each entry once it is applied. Returns how many were applied.
/// Entries appended while this runs are untouched and picked up next time.
Future<int> drainNudgeActionOutbox(Ref ref) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final keys = prefs
      .getKeys()
      .where((k) => k.startsWith(kNudgeActionOutboxKeyPrefix))
      .toList()
    ..sort(); // key embeds the tap time, zero-padded: lexical order is tap order
  if (keys.isEmpty) return 0;

  final actions = ref.read(nudgeActionsProvider);
  var applied = 0;
  for (final key in keys) {
    final action = PendingNudgeAction.tryParse(prefs.getString(key) ?? '');
    if (action != null) {
      final existing = ref.read(nudgeStateProvider(action.ritual));
      switch (action.verb) {
        case NudgeActionVerb.dismiss:
          // Never move a dismissal backwards past one already recorded.
          if (existing.dismissedAt == null ||
              !existing.dismissedAt!.isAfter(action.at)) {
            await actions.dismiss(action.ritual, at: action.at);
          }
        case NudgeActionVerb.snooze:
          // A delayed replay must not shorten a snooze that runs later.
          if (existing.snoozedUntil == null ||
              existing.snoozedUntil!.isBefore(action.until!)) {
            await actions.snooze(
              action.ritual,
              action.until!.difference(action.at),
              at: action.at,
            );
          }
      }
      applied++;
    }
    await prefs.remove(key); // an unreadable entry is dropped, not retried
  }
  return applied;
}

/// Carries still-live legacy notification suppression into the Nudge state,
/// once per device. Does nothing until synced preferences have loaded.
///
/// - `<prefix>_notification_skipped_date == today` becomes a dismiss at now,
///   unless a later dismissal is already recorded.
/// - `<prefix>_notification_snoozed_until` in the future becomes
///   `snoozed_until = max(existing, legacy)`.
///
/// Both SharedPreferences and the synced snapshot are read: a background
/// isolate only ever wrote the former. Expired values are ignored and no
/// legacy key is removed.
Future<void> migrateLegacyNotificationSuppression(Ref ref) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  if (prefs.getBool(kNudgeLegacyMigrationMarkerKey) == true) return;
  final synced = ref.read(syncedPreferencesProvider).asData?.value;
  if (synced == null) return;

  final now = ref.read(clockProvider)();
  final today = '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final actions = ref.read(nudgeActionsProvider);

  for (final ritual in RitualId.values) {
    final skippedKey = '${ritual.keyPrefix}_notification_skipped_date';
    final snoozedKey = '${ritual.keyPrefix}_notification_snoozed_until';
    final existing = ref.read(nudgeStateProvider(ritual));

    final skippedToday = prefs.getString(skippedKey) == today ||
        synced.get<String>(skippedKey) == today;
    if (skippedToday &&
        !(existing.dismissedAt != null && existing.dismissedAt!.isAfter(now))) {
      await actions.dismiss(ritual, at: now);
    }

    DateTime? legacySnoozedUntil;
    for (final raw in [prefs.getString(snoozedKey), synced.get<String>(snoozedKey)]) {
      final parsed = DateTime.tryParse(raw ?? '');
      if (parsed == null || !parsed.isAfter(now)) continue;
      if (legacySnoozedUntil == null || parsed.isAfter(legacySnoozedUntil)) {
        legacySnoozedUntil = parsed;
      }
    }
    if (legacySnoozedUntil != null &&
        (existing.snoozedUntil == null ||
            legacySnoozedUntil.isAfter(existing.snoozedUntil!))) {
      await actions.snooze(ritual, legacySnoozedUntil.difference(now), at: now);
    }
  }

  await prefs.setBool(kNudgeLegacyMigrationMarkerKey, true);
}

/// Keeps the outbox drained for the life of the app. Read once from the app
/// root. Drains once synced preferences are ready, on every app resume, and
/// right after a foreground notification response.
final nudgeActionOutboxDrainerProvider = Provider<void>((ref) {
  var running = false;
  var rerunRequested = false;

  Future<void> run() async {
    if (running) {
      rerunRequested = true;
      return;
    }
    running = true;
    try {
      do {
        rerunRequested = false;
        if (!ref.mounted || !ref.read(nudgePrefsReadyProvider)) return;
        await migrateLegacyNotificationSuppression(ref);
        if (!ref.mounted) return;
        await drainNudgeActionOutbox(ref);
      } while (rerunRequested && ref.mounted);
    } finally {
      running = false;
    }
  }

  final observer = _ResumeObserver(() => unawaited(run()));
  WidgetsBinding.instance.addObserver(observer);
  void onOutboxChanged() => unawaited(run());
  nudgeActionOutboxChanged.addListener(onOutboxChanged);
  ref.onDispose(() {
    WidgetsBinding.instance.removeObserver(observer);
    nudgeActionOutboxChanged.removeListener(onOutboxChanged);
  });

  ref.listen(nudgePrefsReadyProvider, (_, ready) {
    if (ready) unawaited(run());
  }, fireImmediately: true);
});

class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this._onResumed);

  final void Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }
}
