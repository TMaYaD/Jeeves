/// ADR-0010 for the projector: a reduced-in row must reach watching queries.
///
/// Over the **production topology**: `jeeves_domain.sqlite` on disk through
/// `sqlite_async`, every synced name a real table Drift created (#595). The
/// PowerSync-view emulation this file used to install went with the engine.
///
/// **The hazard is smaller than it was, and that is worth stating.** ADR-0010's
/// failure mode was that the `SqliteAsyncDriftConnection` bridge named PowerSync's
/// own *backing* table, never the `todos` view a watcher read, so
/// a projector write invalidated nothing at all. Over real tables the bridge names
/// `todos` — the table that actually changed and the one the watcher declares — so
/// it is now a working second refresh path. The negative assertion this file used
/// to carry ("the same write without the notify is invisible") is therefore false
/// on the new topology and has been removed rather than propped up.
///
/// The notify stays, for the two cases the bridge still does not cover: a watcher
/// that reads across tables the write did not touch (asserted by emission counts
/// in `test/database/action_view_notify_test.dart`), and the window where the
/// bridge is momentarily silent — observed on the first cold start of a new
/// planning day (#342), which is the incident ADR-0010 came out of.
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

void main() {
  late Directory tempDir;
  late SqliteDatabase raw;
  late GtdDatabase domain;
  late SyncDatabase sync;
  late CollectionRegistry registry;
  late Reducer reducer;
  late DomainProjector projector;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    tempDir = Directory.systemTemp.createTempSync('jeeves_550_notify_');
    raw = SqliteDatabase(path: '${tempDir.path}/jeeves_domain.sqlite');
    await raw.initialize();

    // Drift builds the whole schema as real tables on first open — the store's
    // production shape since #595.
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

  test('a projected Outcome reaches the todos watcher', () async {
    final id = _id('outcome');
    final seen = <List<Todo>>[];
    final subscription = domain.todoDao.watchNext().listen(seen.add);
    addTearDown(subscription.cancel);
    await waitUntil(() => seen.isNotEmpty);
    expect(seen.last, isEmpty);

    await projector.project(await reduce('todos', id, outcomeFields('Ship it')));
    await waitUntil(() => seen.last.length == 1);
    expect(seen.last.single.id, id);
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

  test('a projected row round-trips through a plain select(todos), and a '
      're-projection updates only the fields it carries', () async {
    final id = _id('outcome');
    await projector.project(await reduce('todos', id, outcomeFields('Ship it')));

    // A raw row read (as SearchDao does) must not throw — the projected INSERT
    // satisfied every NOT NULL the table declares.
    final row = await (domain.select(domain.todos)
          ..where((todo) => todo.id.equals(id)))
        .getSingle();
    expect(row.title, 'Ship it');

    // A field the op names is updated; a field it omits (here, a local edit to
    // `notes`) is left exactly as the local row holds it.
    await domain.customUpdate(
      'UPDATE "todos" SET "notes" = ? WHERE "id" = ?',
      variables: [Variable<String>('local note'), Variable<String>(id)],
    );
    await projector.project(
        await reduce('todos', id, {'title': 'Ship it, revised'}));
    final reread = await (domain.select(domain.todos)
          ..where((todo) => todo.id.equals(id)))
        .getSingle();
    expect(reread.title, 'Ship it, revised');
    expect(reread.notes, 'local note',
        reason: 'projection overwrote a field the op did not carry');
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
