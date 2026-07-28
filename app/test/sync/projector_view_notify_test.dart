/// ADR-0010 for the projector: a reduced-in row must reach watching views.
///
/// In production every synced table is a PowerSync **view** with INSTEAD OF
/// triggers, so a direct write reports `changes() == 0` and Drift's own stream
/// invalidation never fires — leaving the async bridge as the only refresh
/// path, and the bridge names the *backing* table, not the view. A projected
/// row would therefore land in the store and never appear on screen.
///
/// This recreates that topology on a real on-disk sqlite_async database, the
/// same way `test/database/clarify_routing_view_notify_test.dart` does for the
/// DAO write path, and drives it through [DomainProjector] per collection
/// group. The negative case is asserted too: the identical write *without* the
/// notify leaves the watcher stale, which is what makes the positive case
/// evidence rather than coincidence.
///
/// It also covers search: no FTS index exists — `search_dao` is a read-only
/// query over the live tables — so the notify is the whole requirement for a
/// projected row to be findable.
@TestOn('!browser')
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:drift_sqlite_async/drift_sqlite_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_async/sqlite_async.dart';

import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/search_query.dart';
import 'package:jeeves/models/search_result.dart';
import 'package:jeeves/sync/collection_codecs.dart';
import 'package:jeeves/sync/domain_projector.dart';
import 'package:jeeves/sync/hlc.dart';
import 'package:jeeves/sync/ids.dart' show focusSessionTaskIdFor, jeevesWorkspaceNamespace;
import 'package:jeeves/sync/op_payload.dart';
import 'package:jeeves/sync/reducer.dart';
import 'package:jeeves/sync/sync_database.dart';
import 'package:uuid/uuid.dart';

import 'harness/signal_probe.dart';

const _userId = 'user-1';
const _member = 'dddddddddddddddddddddddddddddddd';
const _baseWallMs = 1800000000000;

String _id(String label) => const Uuid().v5(jeevesWorkspaceNamespace, 'notify/$label');

/// Rewrites [table] from a real table into a PowerSync-style view over a
/// `<table>_data` backing table with INSTEAD OF triggers.
///
/// The backing table is deliberately **unconstrained** beyond its primary key,
/// which is what PowerSync's `ps_data__*` really is (an id and a JSON blob), and
/// the view projects it verbatim. That is what makes this emulation able to
/// catch a projector that leaves a NOT NULL column null: nothing downstream
/// supplies a default, so the null reaches the Drift row read exactly as it
/// would on a store the server has never replicated into.
Future<void> _convertToView(SqliteDatabase raw, String table) async {
  final info = await raw.getAll('PRAGMA table_info($table)');
  final cols = info.map((r) => r['name'] as String).toList();
  final colList = cols.map((c) => '"$c"').join(', ');
  final newValues = cols.map((c) => 'NEW."$c"').join(', ');
  final setClause =
      cols.where((c) => c != 'id').map((c) => '"$c" = NEW."$c"').join(', ');
  final backingCols = [
    for (final column in cols)
      column == 'id' ? '"id" TEXT PRIMARY KEY' : '"$column"',
  ].join(', ');

  await raw.writeTransaction((tx) async {
    await tx.execute('CREATE TABLE ${table}_data ($backingCols)');
    await tx.execute('INSERT INTO ${table}_data ($colList) '
        'SELECT $colList FROM $table');
    await tx.execute('DROP TABLE $table');
    await tx.execute('CREATE VIEW $table AS SELECT $colList FROM ${table}_data');
    await tx.execute('''
CREATE TRIGGER ${table}_insert INSTEAD OF INSERT ON $table BEGIN
  INSERT INTO ${table}_data ($colList) VALUES ($newValues);
END;''');
    await tx.execute('''
CREATE TRIGGER ${table}_update INSTEAD OF UPDATE ON $table BEGIN
  UPDATE ${table}_data SET $setClause WHERE id = OLD.id;
END;''');
    await tx.execute('''
CREATE TRIGGER ${table}_delete INSTEAD OF DELETE ON $table BEGIN
  DELETE FROM ${table}_data WHERE id = OLD.id;
END;''');
  });
}

void main() {
  late Directory tempDir;
  late SqliteDatabase raw;
  late GtdDatabase domain;
  late SyncDatabase sync;
  late CollectionRegistry registry;
  late Reducer reducer;
  late DomainProjector projector;

  const viewed = [
    'todos',
    'todo_tags',
    'tags',
    'actions',
    'time_logs',
    'captures',
    'capture_outcomes',
    'capture_tags',
    'focus_sessions',
    'focus_session_tasks',
    'focus_session_dispositions',
    'user_preferences',
  ];

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    tempDir = Directory.systemTemp.createTempSync('jeeves_550_notify_');
    raw = SqliteDatabase(path: '${tempDir.path}/jeeves.sqlite');
    await raw.initialize();

    final bootstrap = GtdDatabase(SqliteAsyncDriftConnection(raw));
    await bootstrap.customSelect('SELECT 1').get();
    await bootstrap.close();
    for (final table in viewed) {
      await _convertToView(raw, table);
    }
    domain = GtdDatabase(SqliteAsyncDriftConnection(raw));

    sync = SyncDatabase(NativeDatabase.memory());
    registry = CollectionRegistry(sync);
    reducer = Reducer(sync, nowMs: () => _baseWallMs);
    projector = DomainProjector(registry: registry, domain: domain);
  });

  tearDown(() async {
    await domain.close();
    await sync.close();
    await raw.close();
    try {
      tempDir.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort cleanup
    }
  });

  var counter = 0;
  Future<Set<AffectedEntity>> reduce(
    String collection,
    String entityId,
    Map<String, Object?> fields, {
    bool tombstone = false,
  }) async {
    return reducer.apply(
      OpPayload(
        collection: collection,
        entityId: entityId,
        hlc: Hlc(_baseWallMs, counter++, _member),
        fields: {
          for (final entry in fields.entries) entry.key: FieldWrite(entry.value),
        },
        tombstone: tombstone,
      ),
      authorMemberIdHex: _member,
    );
  }

  Map<String, Object?> outcomeFields(String title) => {
        'title': title,
        'created_at': '2026-07-28T09:00:00.000Z',
        'user_id': _userId,
        'clarified': true,
        'intent': 'next',
      };

  test('a projected Outcome reaches the todos watcher — and does not without '
      'the notify', () async {
    final id = _id('outcome');
    final seen = <List<Todo>>[];
    final subscription = domain.todoDao.watchNext().listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty);
    expect(seen.last, isEmpty);

    // The negative case first: the same INSERT the projector runs, with no
    // notify. The view's INSTEAD OF trigger reports changes()==0, the bridge
    // names `todos_data`, and the watcher never re-queries.
    await domain.customInsert(
      'INSERT INTO "todos" ("id", "title", "created_at", "user_id", '
      '"clarified", "intent") VALUES (?, ?, ?, ?, 1, ?)',
      variables: [
        Variable<String>(_id('silent')),
        const Variable<String>('written silently'),
        Variable<DateTime>(DateTime.utc(2026, 7, 28, 9)),
        const Variable<String>(_userId),
        const Variable<String>('next'),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(seen.last, isEmpty, reason: 'a write without the notify must be invisible');

    // The projector's notify re-queries the view, and the silent row surfaces
    // along with the projected one — the store held it all along, the watcher
    // simply had no reason to look.
    await projector.project(await reduce('todos', id, outcomeFields('Ship it')));
    await waitUntil(() => seen.last.length == 2);
    expect(seen.last.map((todo) => todo.id), containsAll([id, _id('silent')]));
  });

  test('a projected Action reaches the actions watcher', () async {
    final outcome = _id('outcome');
    await projector.project(await reduce('todos', outcome, outcomeFields('Ship it')));
    final actionId = _id('action');
    final seen = <Action?>[];
    final subscription =
        domain.actionDao.watchCurrentAction(outcome).listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty);
    expect(seen.last, isNull);

    await projector.project(await reduce(actionsCollection, actionId, {
      'outcome_id': outcome,
      'user_id': _userId,
      'text': 'Draft the memo',
      'role': 'current',
      'created_at': '2026-07-28T09:00:00.000Z',
    }));
    await waitUntil(() => seen.last != null);
    expect(seen.last!.actionText, 'Draft the memo');
  });

  test('a projected Tag reaches the tags watcher', () async {
    final seen = <List<Tag>>[];
    final subscription = domain.tagDao.watchByType('context').listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty);

    await projector.project(await reduce(tagsCollection, _id('tag'), {
      'name': 'errand',
      'type': 'context',
      'user_id': _userId,
    }));
    await waitUntil(() => seen.last.length == 1);
    expect(seen.last.single.name, 'errand');
  });

  test('a projected Capture reaches the Inbox watcher', () async {
    final seen = <List<Capture>>[];
    final subscription = domain.captureDao.watchInbox().listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty);

    await projector.project(await reduce(capturesCollection, _id('capture'), {
      'title': 'a stray thought',
      'created_at': '2026-07-28T09:00:00.000Z',
      'user_id': _userId,
    }));
    await waitUntil(() => seen.last.length == 1);
    expect(seen.last.single.title, 'a stray thought');
  });

  test('a projected TimeLog reaches the active-log watcher', () async {
    final outcome = _id('outcome');
    await projector.project(await reduce('todos', outcome, outcomeFields('Ship it')));
    final seen = <TimeLog?>[];
    final subscription = domain.timeLogDao.watchActiveLog().listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty);

    await projector.project(await reduce(timeLogsCollection, _id('log'), {
      'user_id': _userId,
      'task_id': outcome,
      'started_at': '2026-07-28T09:00:00.000Z',
      'ended_at': null,
    }));
    await waitUntil(() => seen.last != null);
    expect(seen.last!.taskId, outcome);
  });

  test('a projected FocusSession and Plan row reach the session watchers',
      () async {
    final outcome = _id('outcome');
    await projector.project(await reduce('todos', outcome, outcomeFields('Ship it')));
    final sessionId = _id('session');
    final seen = <List<Todo>>[];
    final subscription =
        domain.focusSessionDao.watchActiveSessionTasks().listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty);
    expect(seen.last, isEmpty);

    await projector.project(await reduce(focusSessionsCollection, sessionId, {
      'user_id': _userId,
      'started_at': '2026-07-28T09:00:00.000Z',
      'ended_at': null,
      'current_task_id': null,
    }));
    await projector.project(await reduce(
      focusSessionTasksCollection,
      focusSessionTaskIdFor(sessionId, outcome),
      {
        'focus_session_id': sessionId,
        'task_id': outcome,
        'position': 0,
        'user_id': _userId,
      },
    ));
    await waitUntil(() => seen.last.length == 1);
    expect(seen.last.single.id, outcome);
  });

  test('a projected preference reaches the preferences watcher', () async {
    final seen = <List<UserPreference>>[];
    final subscription =
        domain.userPreferencesDao.watchAll(_userId).listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty);

    await projector.project(await reduce('user_preferences', _id('pref'), {
      'user_id': _userId,
      'key': 'theme',
      'value': '"dark"',
      'updated_at': '2026-07-28T09:00:00.000Z',
    }));
    await waitUntil(() => seen.last.length == 1);
    expect(seen.last.single.key, 'theme');
  });

  test('a projected row is searchable, and the search watcher refreshes',
      () async {
    // No FTS index exists — `search_dao` is a read-only query over the live
    // tables — so ADR-0010's notify is the *whole* requirement for a projected
    // row to become findable.
    final id = _id('outcome');
    final seen = <List<SearchResult>>[];
    final subscription = domain.searchDao
        .search(const SearchQuery(text: 'Quarterly'))
        .listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty);
    expect(seen.last, isEmpty);

    await projector.project(
        await reduce('todos', id, outcomeFields('Quarterly plan')));
    await waitUntil(() => seen.last.any((hit) => hit.todo?.id == id));
  });

  test('a projected row survives a plain select(todos) — the unsynced NOT NULL '
      'column is filled at create time', () async {
    // The trap this closes: `todos.time_spent_minutes` is a dead cache the log
    // carries nothing about (ADR-0030), but it is declared NOT NULL, so a
    // projected row that omitted it read back as null and threw on the null
    // check the moment anything did a raw row read — `SearchDao` among them.
    // Nothing downstream of this emulation supplies a default: the backing
    // table is unconstrained and the view projects it verbatim, exactly like a
    // store the server has never replicated into.
    final id = _id('outcome');
    await projector.project(await reduce('todos', id, outcomeFields('Ship it')));

    final row = await (domain.select(domain.todos)
          ..where((todo) => todo.id.equals(id)))
        .getSingle();
    expect(row.timeSpentMinutes, 0);
    expect(row.title, 'Ship it');

    // Projecting again must not touch the column — it is not a merge input, so
    // whatever the local row holds is what it keeps.
    await domain.customUpdate(
      'UPDATE "todos" SET "time_spent_minutes" = 42 WHERE "id" = ?',
      variables: [Variable<String>(id)],
    );
    await projector.project(
        await reduce('todos', id, {'title': 'Ship it, revised'}));
    final reread = await (domain.select(domain.todos)
          ..where((todo) => todo.id.equals(id)))
        .getSingle();
    expect(reread.title, 'Ship it, revised');
    expect(reread.timeSpentMinutes, 42,
        reason: 'projection overwrote a column it does not own');
  });

  test('a projected tombstone deletes the row and refreshes the watcher',
      () async {
    final id = _id('outcome');
    await projector.project(await reduce('todos', id, outcomeFields('Ship it')));
    final seen = <List<Todo>>[];
    final subscription = domain.todoDao.watchNext().listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty && seen.last.length == 1);

    await projector.project(await reduce('todos', id, const {}, tombstone: true));
    await waitUntil(() => seen.last.isEmpty);
  });
}
