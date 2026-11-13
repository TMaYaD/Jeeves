/// Plan-building search journey (#696), over a real in-memory store.
///
/// On the last Daily Planning step the user searches for an Outcome that is not
/// in Up Next — Someday/Maybe, Waiting For only, or a Next Outcome hidden by
/// today's energy — selects it, and starts the day. The Outcome lands on the
/// session Plan and keeps its Intent. Provider plus real DB, no widgets: a live
/// Drift `watch()` hangs under widget-test fake time (docs/TESTING.md).
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/providers/database_provider.dart';
import 'package:jeeves/providers/focus_session_planning_provider.dart';
import 'package:jeeves/services/notification_service.dart';

import '../test_helpers.dart';

const _userId = 'local';

Future<void> _insert(
  GtdDatabase db,
  String id, {
  String intent = 'next',
  bool withAction = true,
  bool personBlocked = false,
  String? doneAt,
  String? energyLevel,
}) async {
  final now = DateTime.now();
  await db.into(db.todos).insert(TodosCompanion(
        id: Value(id),
        title: Value('Outcome $id'),
        intent: Value(intent),
        doneAt: Value(doneAt),
        energyLevel: Value(energyLevel),
        userId: const Value(_userId),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
  if (withAction) {
    await seedCurrentAction(db,
        outcomeId: id, text: 'work on $id', userId: _userId);
  }
  if (personBlocked) {
    await db.into(db.tags).insert(TagsCompanion(
          id: Value('ptag-$id'),
          name: Value('Trixy-$id'),
          type: const Value('person'),
          userId: const Value(_userId),
        ));
    await db.into(db.todoTags).insert(TodoTagsCompanion(
          id: Value('tt-$id'),
          todoId: Value(id),
          tagId: Value('ptag-$id'),
          userId: const Value(_userId),
        ));
  }
}

void main() {
  setUpAll(configureSqliteForTests);

  late GtdDatabase db;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = GtdDatabase(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      notificationServiceProvider.overrideWithValue(StubNotificationService()),
    ]);
    await _insert(db, 'next');
    await _insert(db, 'someday', intent: 'maybe', withAction: false);
    await _insert(db, 'waiting', withAction: false, personBlocked: true);
    await _insert(db, 'next-chase', personBlocked: true);
    await _insert(db, 'done', doneAt: DateTime.now().toIso8601String());
    await _insert(db, 'trash', intent: 'trash', withAction: false);
    await _insert(db, 'heavy', energyLevel: 'high');
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// Keeps the auto-disposed provider alive and waits until [done] holds.
  Future<List<OffUpNextCandidate>> offUpNextWhere(
    bool Function(List<OffUpNextCandidate>) done,
  ) async {
    final sub = container.listen(
        offUpNextForFocusSessionPlanningProvider, (_, _) {});
    addTearDown(sub.close);
    for (var i = 0; i < 200; i++) {
      final value = sub.read();
      if (done(value)) return value;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return sub.read();
  }

  Map<String, OffUpNextReason> byId(List<OffUpNextCandidate> candidates) =>
      {for (final c in candidates) c.todo.id: c.reason};

  test('offers Someday, Waiting-For-only and energy-hidden Next Outcomes',
      () async {
    container.read(focusSessionPlanningProvider.notifier).setEnergyLevel('low');

    final offered = await offUpNextWhere((c) => c.length >= 3);

    expect(byId(offered), {
      'someday': OffUpNextReason.someday,
      'waiting': OffUpNextReason.waitingFor,
      'heavy': OffUpNextReason.aboveEnergy,
    });
  });

  test('a selected Someday Outcome joins the session Plan, Intent unchanged',
      () async {
    final notifier = container.read(focusSessionPlanningProvider.notifier);
    notifier.setEnergyLevel('low');
    await offUpNextWhere((c) => c.length >= 3);

    notifier.selectTask('someday');
    final remaining = await offUpNextWhere((c) => c.length == 2);
    expect(byId(remaining).keys, isNot(contains('someday')));

    await notifier.startDay();

    final planned = await db.focusSessionDao.watchActiveSessionTasks().first;
    expect(planned.map((t) => t.id), contains('someday'));
    final someday = await (db.select(db.todos)
          ..where((t) => t.id.equals('someday')))
        .getSingle();
    expect(someday.intent, 'maybe');
  });
}
