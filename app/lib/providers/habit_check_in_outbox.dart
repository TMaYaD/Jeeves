/// Carries a "Check in" tap on a Habit's notification into the database.
///
/// A notification action button can run in a background isolate, which has no
/// Riverpod container and no database — only [SharedPreferences]. So the
/// handler appends what the user did, and when, to a device-local outbox
/// ([appendHabitCheckIn]); a main-isolate drainer
/// ([habitCheckInOutboxDrainerProvider]) writes the Check-in and clears the
/// entry. The recorded time, not the drain time, is what the Check-in stores,
/// so a Check-in drained after midnight still counts for the day it was made
/// for.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/daos/habit_dao.dart';
import 'auth_provider.dart';
import 'database_provider.dart';

/// Device-local (not synced) SharedPreferences key prefix of the outbox. Each
/// pending Check-in is its own entry, `<prefix><tap micros>.<random>`, holding
/// one JSON-encoded [PendingHabitCheckIn].
///
/// One key per Check-in, never one shared list: SharedPreferences has no
/// cross-isolate lock, so a read-modify-write of a shared list loses whichever
/// write lands second. A unique key is only ever written once and removed by
/// the drainer that applied it, so appenders and the drainer cannot clobber
/// each other.
const String kHabitCheckInOutboxKeyPrefix = 'habit_check_in_outbox.';

/// One Check-in the user made from a notification, waiting to be written.
class PendingHabitCheckIn {
  const PendingHabitCheckIn({
    required this.checkInId,
    required this.habitId,
    required this.countsForDay,
    required this.at,
  });

  /// The id the Check-in will carry, minted at the tap.
  ///
  /// It travels with the outbox entry, so a drain that is repeated writes the
  /// same Check-in rather than a second one.
  final String checkInId;

  /// The Habit the Check-in is for.
  final String habitId;

  /// The day the Check-in counts for (`YYYY-MM-DD`).
  final String countsForDay;

  /// When the user tapped the button.
  final DateTime at;

  String toJson() => jsonEncode({
        'checkInId': checkInId,
        'habitId': habitId,
        'countsForDay': countsForDay,
        'at': at.toUtc().toIso8601String(),
      });

  /// Returns null for an entry that cannot be read (corrupt or from another
  /// build) so one bad entry cannot wedge the outbox.
  static PendingHabitCheckIn? tryParse(String raw) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final checkInId = m['checkInId'] as String?;
      final habitId = m['habitId'] as String?;
      final countsForDay = m['countsForDay'] as String?;
      final at = DateTime.tryParse(m['at'] as String? ?? '');
      if (checkInId == null ||
          checkInId.isEmpty ||
          habitId == null ||
          habitId.isEmpty ||
          countsForDay == null ||
          countsForDay.isEmpty ||
          at == null) {
        return null;
      }
      return PendingHabitCheckIn(
        checkInId: checkInId,
        habitId: habitId,
        countsForDay: countsForDay,
        at: at,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Bumped whenever this isolate appends to the outbox, so the drainer can run
/// right after a foreground notification response. A background isolate has
/// its own copy that nothing listens to; the drainer picks those entries up on
/// the next app resume instead.
final ValueNotifier<int> habitCheckInOutboxChanged = ValueNotifier<int>(0);

final _outboxKeyRandom = Random();

/// Appends [entry] to the outbox. Safe to call from a background isolate: it
/// writes one fresh key and reads nothing back.
Future<void> appendHabitCheckIn(PendingHabitCheckIn entry) async {
  final prefs = await SharedPreferences.getInstance();
  final key = '$kHabitCheckInOutboxKeyPrefix'
      '${entry.at.toUtc().microsecondsSinceEpoch.toString().padLeft(20, '0')}.'
      '${_outboxKeyRandom.nextInt(1 << 32).toRadixString(16)}';
  await prefs.setString(key, entry.toJson());
  habitCheckInOutboxChanged.value++;
}

/// Writes every outboxed Check-in through the Habit DAO, oldest first, and
/// removes each entry once it is written. Returns how many were written.
///
/// **An entry is removed only when it can never be written.** Two facts about
/// the Habit settle that, and neither of them changes: the Habit is gone, and
/// the Habit has become measured against a target, so its Check-in needs an
/// amount the notification did not carry. Every other failure — a database
/// error, or a Habit that belongs to another user because the session has
/// not been restored yet — leaves the entry for the next drain, so a Check-in
/// is not lost to a fault that may pass.
///
/// An entry that cannot be read at all is dropped, so one bad entry cannot
/// wedge the outbox. Entries appended while this runs are untouched and
/// picked up next time.
Future<int> drainHabitCheckInOutbox({
  required HabitDao dao,
  required String userId,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final keys = prefs
      .getKeys()
      .where((k) => k.startsWith(kHabitCheckInOutboxKeyPrefix))
      .toList()
    ..sort(); // key embeds the tap time, zero-padded: lexical order is tap order
  if (keys.isEmpty) return 0;

  var applied = 0;
  for (final key in keys) {
    final entry = PendingHabitCheckIn.tryParse(prefs.getString(key) ?? '');
    if (entry == null) {
      await prefs.remove(key); // an unreadable entry is dropped, not retried
      continue;
    }
    final outcome = await _writeCheckIn(dao, userId, entry);
    if (outcome == _CheckInOutcome.retryLater) continue;
    if (outcome == _CheckInOutcome.written) applied++;
    await prefs.remove(key);
  }
  return applied;
}

/// What one outboxed Check-in needs from the drain.
enum _CheckInOutcome {
  /// The Check-in is in the database.
  written,

  /// The Check-in can never be written: the Habit is gone, or it has become
  /// measured against a target. The entry is dropped.
  neverWritable,

  /// The Check-in could not be written now, but may be later: a database
  /// error, or a Habit that belongs to another user. The entry waits.
  retryLater,
}

/// Writes one outboxed Check-in, and says whether the entry may go.
Future<_CheckInOutcome> _writeCheckIn(
  HabitDao dao,
  String userId,
  PendingHabitCheckIn entry,
) async {
  try {
    // A Habit that is not there cannot be checked in to, now or later.
    final habit = await dao.habitById(entry.habitId);
    if (habit == null) return _CheckInOutcome.neverWritable;
    // A Habit that belongs to another user is what a drain sees before the
    // stored session has been restored: the entry waits for the right user.
    if (habit.userId != userId) return _CheckInOutcome.retryLater;
    await dao.addCheckIn(
      habitId: entry.habitId,
      userId: userId,
      countsForDay: entry.countsForDay,
      now: entry.at,
      checkInId: entry.checkInId,
    );
    return _CheckInOutcome.written;
  } on ArgumentError {
    // The Habit became measured against a target since the tap, so its
    // Check-in needs an amount the notification did not carry.
    return _CheckInOutcome.neverWritable;
  } catch (e) {
    debugPrint('A habit Check-in from a notification was not written: $e');
    return _CheckInOutcome.retryLater;
  }
}

/// Keeps the outbox drained for the life of the app. Read once from the app
/// root. Drains on every app resume and right after a foreground notification
/// response.
///
/// **The drain waits for the stored session.** `'local'` is the pre-auth
/// placeholder, so a drain that ran before the restore would write as
/// `'local'` and every Habit of a signed-in account would refuse it as
/// another user's — and the Check-in would be lost. The drain waits for the
/// restore, and runs again when the account changes.
final habitCheckInOutboxDrainerProvider = Provider<void>((ref) {
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
        if (!ref.mounted) return;
        // The session has to be restored first: until it is, the user id is
        // the 'local' placeholder and the account's Habits refuse the write.
        await _awaitRestoredSession(ref);
        if (!ref.mounted) return;
        await drainHabitCheckInOutbox(
          dao: ref.read(databaseProvider).habitDao,
          userId: ref.read(currentUserIdProvider),
        );
      } while (rerunRequested && ref.mounted);
    } finally {
      running = false;
    }
  }

  final observer = _ResumeObserver(() => unawaited(run()));
  WidgetsBinding.instance.addObserver(observer);
  void onOutboxChanged() => unawaited(run());
  habitCheckInOutboxChanged.addListener(onOutboxChanged);
  ref.onDispose(() {
    WidgetsBinding.instance.removeObserver(observer);
    habitCheckInOutboxChanged.removeListener(onOutboxChanged);
  });

  // The drain runs once the session is there, and again when the account
  // changes: a sign-in replaces the account the outbox is written for.
  ref.listen(currentUserIdProvider, (_, _) => unawaited(run()),
      fireImmediately: true);
});

/// Waits for the stored session to be restored.
///
/// The device starts on the `'local'` placeholder, which is not an account:
/// a write made before the restore names no account, and the rows of a
/// signed-in account refuse it. A restore that fails leaves the device
/// signed out, and the drain then runs as `'local'` — where an entry it
/// cannot write waits for the next drain rather than being lost.
Future<void> _awaitRestoredSession(Ref ref) async {
  try {
    await ref.read(authTokenProvider.future);
  } catch (_) {
    // The restore failed. The device keeps the placeholder, and the drain
    // runs for it.
  }
}

class _ResumeObserver with WidgetsBindingObserver {
  _ResumeObserver(this._onResumed);

  final void Function() _onResumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResumed();
  }
}
