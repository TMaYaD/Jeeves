/// ADR-0010 notify regression for `actions` (issue #472), sibling of
/// `clarify_routing_view_notify_test.dart`.
///
/// Over the **production topology**: a `jeeves_domain.sqlite` on disk, opened
/// through `sqlite_async`, with every synced name a real table Drift created
/// (#595). This file used to rewrite those tables into PowerSync-style views with
/// INSTEAD OF triggers, because that was what production served and a Drift write
/// against a view reports `changes() == 0`. The store is Drift's own now, so the
/// emulation would be testing a topology nothing runs.
///
/// What is still under test is the part real tables do not give for free: **a
/// write to one table refreshing a watcher on another.** Drift will not
/// invalidate a `todos` watcher because `actions` changed, and several of these
/// transactions write nothing to `todos` at all — but the `todos` notify must
/// still fire, because two GTD list watchers name only `{todoTags, tags}` in
/// `readsFrom`. That is why the `todos` watchers assert on emission *counts*
/// rather than values: counting fails if the notify is dropped as "redundant"
/// even though no value would have moved.
@TestOn('!browser')
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'package:jeeves/database/gtd_database.dart';

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not met within $timeout', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory tempDir;
  late SqliteDatabase raw;
  late GtdDatabase db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('jeeves_472_');
    final dbPath = '${tempDir.path}/jeeves.sqlite';

    raw = SqliteDatabase(path: dbPath);
    await raw.initialize();

    // Drift builds the whole schema as real tables on first open — the store's
    // production shape since #595.
    db = GtdDatabase(SqliteAsyncDriftConnection(raw));
    await db.into(db.todos).insert(TodosCompanion(
          id: const Value('o1'),
          title: const Value('Outcome'),
          userId: const Value('u1'),
          createdAt: Value(DateTime.parse('2026-07-01T09:00:00.000Z')),
          clarified: const Value(true),
        ));
  });

  tearDown(() async {
    await db.close();
    await raw.close();
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  Stream<List<String>> watchActionTexts() => db
      .customSelect(
        "SELECT text FROM actions WHERE outcome_id = 'o1' AND role = 'current'",
        readsFrom: {db.actions},
      )
      .watch()
      .map((rows) => rows.map((r) => r.read<String>('text')).toList());

  /// A `todos`-only watcher. It reads `title` — a column these transactions do
  /// not touch — deliberately: the assertion is that the stream *re-emits*,
  /// which is what `notifyTodosViewWrite` is for and the only thing a watcher
  /// naming a different table in `readsFrom` can rely on.
  Stream<List<String>> watchTodoTitles() => db
      .customSelect(
        "SELECT title FROM todos WHERE id = 'o1'",
        readsFrom: {db.todos},
      )
      .watch()
      .map((rows) => rows.map((r) => r.read<String>('title')).toList());

  Stream<List<String?>> watchEnergyLevels() => db
      .customSelect(
        "SELECT energy_level FROM actions WHERE outcome_id = 'o1'",
        readsFrom: {db.actions},
      )
      .watch()
      .map((rows) => rows.map((r) => r.read<String?>('energy_level')).toList());

  test('an ActionDao primitive refreshes an actions watcher', () async {
    final seen = <List<String>>[];
    final sub = watchActionTexts().listen(seen.add);
    addTearDown(sub.cancel);

    await _waitUntil(() => seen.isNotEmpty);
    expect(seen.last, isEmpty);

    await db.actionDao.setCurrentAction('o1', 'call the plumber');

    await _waitUntil(() => seen.last.length == 1);
    expect(seen.last, ['call the plumber']);
  });

  // The planned-row effort sheet (#477) edits an Action's metadata and nothing
  // else. The task-detail widget test cannot catch a dropped notify — its
  // harness hand-cranks the plan-section streams off DAO reads rather than
  // subscribing to the real one — so the live-refresh claim is pinned here,
  // against the production store topology.
  test('editAction refreshes an actions watcher on a metadata-only edit',
      () async {
    await db.actionDao.addPlannedAction('o1', 'draft the brief');
    final planned = await db.actionDao.getPlannedActions('o1');
    final id = planned.single.id;

    final seen = <List<String?>>[];
    final sub = watchEnergyLevels().listen(seen.add);
    addTearDown(sub.cancel);

    await _waitUntil(() => seen.isNotEmpty);
    expect(seen.last, [null]);

    // Text untouched — only the metadata moves.
    await db.actionDao.editAction(id, energyLevel: 'high', timeEstimate: 45);

    await _waitUntil(() => seen.last.contains('high'));
    expect(seen.last, ['high']);
  });

  test('editAction refreshes an actions watcher when a clear flag nulls '
      'the metadata', () async {
    await db.actionDao.addPlannedAction('o1', 'draft the brief',
        energyLevel: 'high', timeEstimate: 45);
    final id = (await db.actionDao.getPlannedActions('o1')).single.id;

    final seen = <List<String?>>[];
    final sub = watchEnergyLevels().listen(seen.add);
    addTearDown(sub.cancel);

    await _waitUntil(() => seen.isNotEmpty && seen.last.contains('high'));

    await db.actionDao
        .editAction(id, clearEnergyLevel: true, clearTimeEstimate: true);

    await _waitUntil(() => seen.last.contains(null));
    expect(seen.last, [null]);
  });

  test('completeCurrentAction refreshes both watchers — it now writes '
      'nothing to `todos` at all, so the todos notify is unconditional and '
      'cannot be gated on the stamp (which completion never moves)', () async {
    await db.todoDao.setCurrentActionText('o1', 'call the plumber');

    final todoEmissions = <List<String>>[];
    final actionRoles = <List<String>>[];
    final subTodo = watchTodoTitles().listen(todoEmissions.add);
    final subAction = db
        .customSelect(
          "SELECT role FROM actions WHERE outcome_id = 'o1'",
          readsFrom: {db.actions},
        )
        .watch()
        .map((rows) => rows.map((r) => r.read<String>('role')).toList())
        .listen(actionRoles.add);
    addTearDown(subTodo.cancel);
    addTearDown(subAction.cancel);

    await _waitUntil(() =>
        todoEmissions.isNotEmpty &&
        actionRoles.isNotEmpty &&
        actionRoles.last.contains('current'));
    final todoEmissionsBefore = todoEmissions.length;

    await db.actionDao.completeCurrentAction('o1');

    await _waitUntil(() =>
        actionRoles.last.contains('done') &&
        todoEmissions.length > todoEmissionsBefore);
    expect(actionRoles.last, ['done']);
    expect(todoEmissions.length, greaterThan(todoEmissionsBefore),
        reason: 'the todos watcher must still be refreshed');
  });

  test('clearCurrentAction refreshes both watchers — its `todos` write is '
      'now only the stamp, which an abandon always moves', () async {
    await db.todoDao.setCurrentActionText('o1', 'call the plumber');

    final todoEmissions = <List<String>>[];
    final actionRoles = <List<String>>[];
    final subTodo = watchTodoTitles().listen(todoEmissions.add);
    final subAction = db
        .customSelect(
          "SELECT role FROM actions WHERE outcome_id = 'o1'",
          readsFrom: {db.actions},
        )
        .watch()
        .map((rows) => rows.map((r) => r.read<String>('role')).toList())
        .listen(actionRoles.add);
    addTearDown(subTodo.cancel);
    addTearDown(subAction.cancel);

    await _waitUntil(() =>
        todoEmissions.isNotEmpty &&
        actionRoles.isNotEmpty &&
        actionRoles.last.contains('current'));
    final todoEmissionsBefore = todoEmissions.length;

    await db.actionDao.clearCurrentAction('o1');

    await _waitUntil(() =>
        actionRoles.last.contains('superseded') &&
        todoEmissions.length > todoEmissionsBefore);
    expect(actionRoles.last, ['superseded']);
    expect(todoEmissions.length, greaterThan(todoEmissionsBefore),
        reason: 'the todos watcher must still be refreshed');
  });

  test('completeCurrentAction refreshes a time_logs watcher when it '
      'closes the open log (ADR-0010, issue #476)', () async {
    await db.actionDao.setCurrentAction('o1', 'call the plumber');
    final current = await db.actionDao.getCurrentAction('o1');
    // Open a stint against the current Action (through the view's trigger).
    await db.into(db.timeLogs).insert(TimeLogsCompanion(
          id: const Value('log-1'),
          userId: const Value('u1'),
          taskId: const Value('o1'),
          actionId: Value(current!.id),
          startedAt:
              Value(DateTime.parse('2026-07-01T10:00:00.000Z').toIso8601String()),
        ));

    final openCounts = <int>[];
    final sub = db
        .customSelect(
          'SELECT COUNT(*) AS c FROM time_logs WHERE ended_at IS NULL',
          readsFrom: {db.timeLogs},
        )
        .watch()
        .map((rows) => rows.first.read<int>('c'))
        .listen(openCounts.add);
    addTearDown(sub.cancel);

    await _waitUntil(() => openCounts.isNotEmpty && openCounts.last == 1);

    // Completing the Action closes the log; the time_logs view write reports
    // changes()==0, so only notifyTimeLogsViewWrite refreshes this watcher.
    await db.actionDao.completeCurrentAction('o1');

    await _waitUntil(() => openCounts.last == 0);
    expect(openCounts.last, 0);
  });

  test('TodoDao.setCurrentActionText refreshes both the todos and actions '
      'watchers', () async {
    final todoEmissions = <List<String>>[];
    final actionTexts = <List<String>>[];
    final subTodo = watchTodoTitles().listen(todoEmissions.add);
    final subAction = watchActionTexts().listen(actionTexts.add);
    addTearDown(subTodo.cancel);
    addTearDown(subAction.cancel);

    await _waitUntil(() => todoEmissions.isNotEmpty && actionTexts.isNotEmpty);
    final todoEmissionsBefore = todoEmissions.length;

    await db.todoDao.setCurrentActionText('o1', 'draft the plan');

    await _waitUntil(() =>
        actionTexts.last.length == 1 &&
        actionTexts.last.first == 'draft the plan' &&
        todoEmissions.length > todoEmissionsBefore);
    expect(actionTexts.last, ['draft the plan']);
    expect(todoEmissions.length, greaterThan(todoEmissionsBefore),
        reason: 'the todos watcher must still be refreshed');
  });
}
