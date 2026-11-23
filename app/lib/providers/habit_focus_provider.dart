/// Focus Mode on a Habit (issue #405): the Sprint timer of a Habit and the
/// writes that drive it.
///
/// **The record is the source of truth.** The state is derived from the open
/// Habit log and its Sprints through `deriveHabitSprintTimerState`; the
/// one-second ticker only re-evaluates it, so a Focus left open when the app
/// was killed resumes from the record. Sprint and break lengths come from the
/// existing Focus settings.
///
/// **One thing at a time.** Starting a Focus on a Habit ends an Outcome
/// engagement in the same transaction that opens it;
/// `FocusModeNotifier.startFocus` closes an open Focus on a Habit. No notification is scheduled for a Focus on a Habit.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:drift/drift.dart' show TableUpdateQuery;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/habit_focus_dao.dart' show HabitFocusRecords;
import '../database/gtd_database.dart';
import '../models/habit_focus_timer.dart';
import 'auth_provider.dart';
import 'clock_provider.dart';
import 'database_provider.dart';
import 'focus_session_provider.dart';
import 'focus_settings_provider.dart';
import '../database/daos/habit_dao.dart' show HabitState;
import 'habits_provider.dart';
import 'sprint_timer_provider.dart' show SprintTimerState;
import 'synced_preferences_provider.dart' show syncedPreferencesProvider;

final habitFocusProvider =
    NotifierProvider<HabitFocusNotifier, SprintTimerState>(
  HabitFocusNotifier.new,
);

class HabitFocusNotifier extends Notifier<SprintTimerState> {
  Timer? _ticker;
  StreamSubscription<Object?>? _tableUpdates;
  bool _disposed = false;

  HabitTimeLog? _openLog;
  List<HabitSprint> _sprints = const [];
  int _reloadGeneration = 0;
  Habit? _habit;

  @override
  SprintTimerState build() {
    ref.onDispose(() {
      _disposed = true;
      _ticker?.cancel();
      _tableUpdates?.cancel();
    });
    final db = ref.read(databaseProvider);
    _tableUpdates = db
        .tableUpdates(
            TableUpdateQuery.onAllTables([db.habitTimeLogs, db.habitSprints]))
        .listen((_) => unawaited(_reload()));
    unawaited(_reload());
    return const SprintTimerState();
  }

  int get _sprintMinutes =>
      ref.read(focusSettingsProvider).sprintDurationMinutes;
  int get _breakMinutes =>
      ref.read(focusSettingsProvider).shortBreakDurationMinutes;
  int get _longBreakMinutes =>
      ref.read(focusSettingsProvider).longBreakDurationMinutes;
  int get _sprintsBeforeLongBreak =>
      ref.read(focusSettingsProvider).sprintsBeforeLongBreak;
  String get _userId => ref.read(currentUserIdProvider);

  /// Starts a Focus on [habitId], or adopts the one already open on it.
  ///
  /// Ends an Outcome engagement first, and closes an open Focus on another
  /// Habit. Throws a [StateError] for a Habit with no estimate or one that is
  /// not active today.
  Future<void> start(String habitId) async {
    if (state.isProcessing) return;
    final db = ref.read(databaseProvider);
    state = state.copyWith(isProcessing: true);
    try {
      await _reload();
      if (state.isActive && state.activeTaskId == habitId) return;
      await _awaitSyncedSettings();
      // Validates the Habit first and ends any Outcome engagement still open
      // in the store in the same transaction: a Habit that is rejected leaves
      // the engagement running.
      await db.habitFocusDao.openHabitFocus(
        habitId: habitId,
        userId: _userId,
        plannedSprintMinutes: _sprintMinutes,
        now: ref.read(clockProvider)(),
      );
      // The store is settled, the Outcome log and a session's pointer
      // included; only the in-memory state that mirrors it is left to clear.
      ref.read(focusModeProvider.notifier).resetState();
      await _reload();
    } finally {
      if (!_disposed && state.isProcessing) {
        state = state.copyWith(isProcessing: false);
      }
    }
  }

  /// Ends the running Sprint early; the gap that follows is a break.
  Future<void> startBreak() async {
    if (!state.isFocus || state.isProcessing) return;
    await ref.read(databaseProvider).habitFocusDao.endRunningHabitSprint(
          userId: _userId,
          now: ref.read(clockProvider)(),
        );
    await _reload();
  }

  /// Starts the next Sprint of the open Focus.
  Future<void> startSprint() async {
    if (!state.isActive || state.isProcessing) return;
    state = state.copyWith(isProcessing: true);
    try {
      await _awaitSyncedSettings();
      await ref.read(databaseProvider).habitFocusDao.startHabitSprint(
            userId: _userId,
            plannedSprintMinutes: _sprintMinutes,
            now: ref.read(clockProvider)(),
          );
      await _reload();
    } finally {
      if (!_disposed && state.isProcessing) {
        state = state.copyWith(isProcessing: false);
      }
    }
  }

  /// Stops: ends the running Sprint and the open log.
  Future<void> stop() async {
    await ref.read(databaseProvider).habitFocusDao.closeHabitFocus(
          userId: _userId,
          now: ref.read(clockProvider)(),
        );
    await _reload();
  }

  /// The Sprint length is a synced preference that loads after launch; until
  /// it has, the notifier holds defaults and the wrong length would be
  /// recorded (and synced), as the Outcome Sprint path avoids.
  Future<void> _awaitSyncedSettings() async {
    ref.read(focusSettingsProvider); // starts the settings watch if not yet
    try {
      // `exists`: a container that replaced the settings (as tests do) never
      // starts the synced-preferences load, and there is nothing to wait for.
      // ignore: deprecated_member_use
      if (ref.exists(syncedPreferencesProvider)) {
        await ref.read(syncedPreferencesProvider.future);
      }
    } catch (error) {
      debugPrint('Sprint length: synced preferences unavailable: $error');
    }
  }

  Future<void> _reload() async {
    if (_disposed) return;
    final generation = ++_reloadGeneration;
    final db = ref.read(databaseProvider);
    final log = await db.habitFocusDao.openHabitTimeLog(_userId);
    var sprints = const <HabitSprint>[];
    Habit? habit;
    if (log != null) {
      sprints = await db.habitFocusDao.sprintsOfLog(log);
      habit = _habit?.id == log.habitId
          ? _habit
          : await db.habitDao.habitById(log.habitId);
    }
    // A newer reload started meanwhile: its result is the later read.
    if (_disposed || generation != _reloadGeneration) return;
    _openLog = log;
    _sprints = sprints;
    _habit = habit;
    _recompute();
  }

  void _recompute() {
    if (_disposed) return;
    final previous = state;
    final next = deriveHabitSprintTimerState(
      openLog: _openLog,
      sprints: _sprints,
      sprintMinutesSetting: _openLog == null ? 20 : _sprintMinutes,
      breakMinutesSetting: _openLog == null ? 3 : _breakMinutes,
      longBreakMinutesSetting: _longBreakMinutes,
      sprintsBeforeLongBreakSetting: _sprintsBeforeLongBreak,
      estimateMinutes: _habit?.timeEstimateMinutes,
      now: ref.read(clockProvider)(),
      habitTitle: _habit?.title,
    ).copyWith(isProcessing: previous.isProcessing);
    state = next;
    final counting =
        next.isActive && !(next.isOvertime && next.overtime >= next.total);
    if (counting) {
      _ticker ??=
          Timer.periodic(const Duration(seconds: 1), (_) => _recompute());
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }
}

/// The open Focus on [habitId] and its Sprints, live.
final habitFocusRecordsProvider = StreamProvider.autoDispose
    .family<HabitFocusRecords, String>((ref, habitId) => ref
        .watch(databaseProvider)
        .habitFocusDao
        .watchHabitFocusRecords(habitId));

/// How the Habit detail offers Focus Mode.
enum HabitFocusEntry {
  /// No offer: the Habit has no estimate or is not active today.
  none,

  /// "Start Focus Mode on this Habit".
  start,

  /// A Focus is open on it (the app was closed mid-Focus): "Resume Focus".
  resume,
}

/// Whether the detail of [habitId] offers to start or resume Focus Mode.
final habitFocusEntryProvider =
    Provider.autoDispose.family<HabitFocusEntry, String>((ref, habitId) {
  final habit = ref.watch(habitByIdProvider(habitId)).value;
  final state = ref.watch(habitStateTodayProvider(habitId));
  if (habit?.timeEstimateMinutes == null || state != HabitState.active) {
    return HabitFocusEntry.none;
  }
  final records = ref.watch(habitFocusRecordsProvider(habitId)).value;
  return records?.openLog != null
      ? HabitFocusEntry.resume
      : HabitFocusEntry.start;
});
