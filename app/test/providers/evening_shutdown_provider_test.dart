import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/evening_shutdown_provider.dart';
import '../test_helpers.dart';

// Must match currentUserIdProvider.build() default so the notifier finds tasks.
const _uid = 'local';

// Minimal stub — avoids hitting NotificationService platform channels in tests.
class _StubShutdownNotifier extends EveningShutdownNotifier {
  @override
  Future<void> skipShutdownToday() async {
    await persistShutdownSkipToday();
  }

  @override
  Future<void> snoozeShutdownNotification(int minutes) async {
    final until = DateTime.now().add(Duration(minutes: minutes));
    await persistShutdownSnoozedUntil(until);
  }
}

ProviderContainer _container(GtdDatabase db) => ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        eveningShutdownProvider.overrideWith(() => _StubShutdownNotifier()),
      ],
    );

void main() {
  setUpAll(configureSqliteForTests);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    shutdownCompletionNotifier.value = false;
    shutdownBannerDismissedNotifier.value = false;
  });

  group('EveningShutdownNotifier', () {
    late GtdDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = GtdDatabase(NativeDatabase.memory());
      container = _container(db);
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    // ---- Step navigation -------------------------------------------------------

    test('starts at step 0', () {
      final state = container.read(eveningShutdownProvider);
      expect(state.currentStep, equals(0));
    });

    test('advanceStep increments currentStep', () {
      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.advanceStep();
      expect(container.read(eveningShutdownProvider).currentStep, equals(1));
    });

    test('advanceStep clamps at max step', () {
      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.goToStep(2); // at max
      notifier.advanceStep(); // try to go beyond
      expect(container.read(eveningShutdownProvider).currentStep, equals(2));
    });

    test('goToStep sets step directly', () {
      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.goToStep(2);
      expect(container.read(eveningShutdownProvider).currentStep, equals(2));
    });

    // ---- closeDay ------------------------------------------------------------

    test('closeDay sets shutdownCompletionNotifier to true', () async {
      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.closeDay();
      expect(shutdownCompletionNotifier.value, isTrue);
    });

    test('closeDay persists completion date to SharedPreferences', () async {
      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.closeDay();

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('shutdown_ritual_completed_date');
      expect(stored, isNotNull);
    });

    test('closeDay resets step to 0', () async {
      final notifier = container.read(eveningShutdownProvider.notifier);
      notifier.goToStep(2);
      await notifier.closeDay();
      expect(container.read(eveningShutdownProvider).currentStep, equals(0));
    });

    // ---- dismissBannerForToday -----------------------------------------------

    test('dismissBannerForToday sets shutdownBannerDismissedNotifier', () async {
      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.dismissBannerForToday();
      expect(shutdownBannerDismissedNotifier.value, isTrue);
    });

    test('dismissBannerForToday persists dismissed date', () async {
      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.dismissBannerForToday();

      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('shutdown_banner_dismissed_date');
      expect(stored, isNotNull);
    });

    // ---- rolloverTask --------------------------------------------------------

    test('rolloverTask preselects task for tomorrow', () async {
      final taskId = await _insertTask(db,
          state: GtdState.nextAction.value,
          selectedForToday: true,
          dailySelectionDate: _todayStr());

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.rolloverTask(taskId);

      final task = await db.todoDao.getTodo(taskId, _uid);
      expect(task?.selectedForToday, isTrue);
      expect(task?.dailySelectionDate, equals(_tomorrowStr()));
    });

    // ---- returnToNextActions -------------------------------------------------

    test('returnToNextActions clears task daily selection', () async {
      final taskId = await _insertTask(db,
          state: GtdState.nextAction.value,
          selectedForToday: true,
          dailySelectionDate: _todayStr());

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.returnToNextActions(taskId);

      final task = await db.todoDao.getTodo(taskId, _uid);
      expect(task?.selectedForToday, isNull);
      expect(task?.dailySelectionDate, isNull);
    });

    // ---- deferTask -----------------------------------------------------------

    test('deferTask transitions task to somedayMaybe', () async {
      final taskId = await _insertTask(db,
          state: GtdState.nextAction.value,
          selectedForToday: true,
          dailySelectionDate: _todayStr());

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.deferTask(taskId);

      final task = await db.todoDao.getTodo(taskId, _uid);
      expect(task?.state, equals(GtdState.somedayMaybe.value));
    });

    // ---- DAO queries (verify data via DAO, not stream providers) -------------

    test('completed tasks are visible via DAO after closeDay cycle', () async {
      await _insertTask(db,
          state: GtdState.done.value,
          selectedForToday: true,
          dailySelectionDate: _todayStr());

      final result = await db.todoDao
          .watchCompletedToday(_uid, _todayStr())
          .first;
      expect(result.length, equals(1));
    });

    test('unfinished tasks visible via DAO and empty after rollover', () async {
      final taskId = await _insertTask(db,
          state: GtdState.nextAction.value,
          selectedForToday: true,
          dailySelectionDate: _todayStr());

      final before = await db.todoDao
          .watchUnfinishedSelectedToday(_uid, _todayStr())
          .first;
      expect(before.map((t) => t.id), contains(taskId));

      final notifier = container.read(eveningShutdownProvider.notifier);
      await notifier.rolloverTask(taskId);

      final after = await db.todoDao
          .watchUnfinishedSelectedToday(_uid, _todayStr())
          .first;
      expect(after, isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _todayStr() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

String _tomorrowStr() {
  final tomorrow = DateTime.now().add(const Duration(days: 1));
  return '${tomorrow.year.toString().padLeft(4, '0')}-'
      '${tomorrow.month.toString().padLeft(2, '0')}-'
      '${tomorrow.day.toString().padLeft(2, '0')}';
}

Future<String> _insertTask(
  GtdDatabase db, {
  required String state,
  bool? selectedForToday,
  String? dailySelectionDate,
  int timeSpentMinutes = 0,
}) async {
  final id = 'task-${DateTime.now().microsecondsSinceEpoch}';
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
    id: Value(id),
    title: Value('Task $id'),
    state: Value(state),
    userId: Value(_uid),
    createdAt: Value(now),
    updatedAt: Value(now),
    selectedForToday: Value(selectedForToday),
    dailySelectionDate: Value(dailySelectionDate),
    timeSpentMinutes: Value(timeSpentMinutes),
  ));
  return id;
}

