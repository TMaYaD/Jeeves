/// Every collection, end to end: DAO write on A → reduce and project on B →
/// the same domain row.
///
/// This is the layer #553 has to trust. The reducer's vectors pin the merge;
/// these pin the *codecs* — that a row written through a real DAO on one device
/// reconstructs, column for column, on a device that only ever saw the ops.
@TestOn('!browser')
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';

import 'package:jeeves/database/daos/focus_session_dao.dart'
    show focusSessionDispositionIdFor;
import 'package:jeeves/database/gtd_database.dart';
import 'package:jeeves/models/todo.dart' show RoutingKind;
import 'package:jeeves/sync/ids.dart'
    show focusSessionTaskIdFor, jeevesWorkspaceNamespace;
import 'package:uuid/uuid.dart';

import '../test_helpers.dart';
import 'harness/reduced_state.dart';
import 'harness/sim_device.dart';
import 'harness/sim_workspace.dart';

const _userId = 'sim-user';

/// Entity ids are canonical lowercase UUIDs on the wire — the payload codec
/// rejects anything else rather than normalising it, and authoring runs that
/// same codec, so a fixture id like 'outcome-1' is refused by `capture()` itself
/// with `malformed_payload`. Deriving them keeps the harness reproducible
/// without hand-writing UUID literals.
String _id(String label) => const Uuid().v5(jeevesWorkspaceNamespace, 'sim/$label');

/// `todos.time_spent_minutes` never travels on the wire — a dead cache
/// (ADR-0030) the projector only ever fills with its declared default at create
/// time — so it is excluded from every cross-device comparison.
const _deadCache = {'time_spent_minutes'};

void main() {
  setUpAll(configureSqliteForTests);

  late SimWorkspace workspace;
  late SimDevice a;
  late SimDevice b;

  setUp(() async {
    workspace = await SimWorkspace.create();
    a = workspace.a;
    b = workspace.b;
  });
  tearDown(() async => workspace.close());

  Future<void> expectTableConverges(String table, {String orderBy = 'id'}) async {
    final rowsA = await domainRows(a.domain, table,
        exclude: _deadCache, orderBy: orderBy);
    final rowsB = await domainRows(b.domain, table,
        exclude: _deadCache, orderBy: orderBy);
    expect(rowsB, rowsA, reason: '$table did not converge');
    expect(rowsA, isNotEmpty, reason: '$table was never populated');
  }

  Future<String> outcomeOnA({String? id}) async {
    id ??= _id('outcome-1');
    await a.domain.todoDao.insertOutcome(
      id: id,
      title: 'Ship the thing',
      userId: _userId,
      notes: 'with context',
      energyLevel: 'low',
      timeEstimate: 25,
      dueDate: a.clock.asDateTime,
      captureSource: 'voice',
      now: a.clock.asDateTime,
    );
    return id;
  }

  test('todos round-trip column for column', () async {
    final id = await outcomeOnA();
    await workspace.syncAll();
    await expectTableConverges('todos');
    final row = await b.domain.todoDao.getTodo(id);
    expect(row!.title, 'Ship the thing');
    expect(row.notes, 'with context');
    expect(row.captureSource, 'voice');
  });

  test('actions and their Outcome metadata mirror round-trip', () async {
    final id = await outcomeOnA();
    await a.domain.todoDao
        .setCurrentActionText(id, 'Draft the memo', now: a.clock.asDateTime);
    await workspace.syncAll();
    await expectTableConverges('actions');
    final current = await b.domain.actionDao.getCurrentAction(id);
    expect(current!.actionText, 'Draft the memo');
    expect(current.role, 'current');
  });

  test('tags and todo_tags round-trip, junction id included', () async {
    final id = await outcomeOnA();
    final tagId = await a.domain.tagDao.findOrCreateTag('errand', 'context', _userId);
    await a.domain.tagDao.assignTag(id, tagId, _userId);
    await workspace.syncAll();
    await expectTableConverges('tags');
    await expectTableConverges('todo_tags');
  });

  test('captures and both capture junctions round-trip', () async {
    final id = await outcomeOnA();
    await a.domain.captureDao.insertCapture(CapturesCompanion(
      id: Value(_id('capture-1')),
      title: const Value('a stray thought'),
      captureSource: const Value('voice'),
      userId: const Value(_userId),
      createdAt: Value(a.clock.asDateTime),
    ));
    final tagId = await a.domain.tagDao.findOrCreateTag('errand', 'context', _userId);
    await a.domain.captureDao.assignTagHint(_id('capture-1'), tagId, _userId);
    await a.domain.captureDao
        .linkOutcome(_id('capture-1'), id, _userId, at: a.clock.asDateTime);
    await a.domain.captureDao.stampClarified(_id('capture-1'), at: a.clock.asDateTime);
    await workspace.syncAll();
    await expectTableConverges('captures');
    await expectTableConverges('capture_outcomes');
    await expectTableConverges('capture_tags');
  });

  test('time_logs round-trip with their opaque TEXT timestamps', () async {
    final id = await outcomeOnA();
    await a.domain.timeLogDao
        .openLog(taskId: id, userId: _userId, now: a.clock.asDateTime);
    a.clock.advance(60000);
    await a.domain.timeLogDao.closeLog(taskId: id, now: a.clock.asDateTime);
    await workspace.syncAll();
    await expectTableConverges('time_logs');
  });

  test('focus_session_tasks.id is realigned onto its pair derivation on every '
      'device, including the author', () async {
    final id = await outcomeOnA();
    final sessionId = await a.domain.focusSessionDao
        .openSession(userId: _userId, taskIds: [id], now: a.clock.asDateTime);
    await workspace.syncAll();

    final derived = focusSessionTaskIdFor(sessionId, id);
    for (final device in [a, b]) {
      final row = await device.domain
          .customSelect('SELECT id FROM focus_session_tasks')
          .getSingle();
      expect(row.read<String>('id'), derived,
          reason: '${device.label} kept a local random id');
    }
    await expectTableConverges('focus_sessions');
    await expectTableConverges('focus_session_tasks', orderBy: 'position');
  });

  test('focus_session_dispositions round-trip for off-Plan engagement',
      () async {
    final planned = await outcomeOnA(id: _id('planned-1'));
    await a.domain.todoDao.insertOutcome(
      id: _id('offplan-1'),
      title: 'Off-Plan',
      userId: _userId,
      now: a.clock.asDateTime,
    );
    final sessionId = await a.domain.focusSessionDao
        .openSession(userId: _userId, taskIds: [planned], now: a.clock.asDateTime);
    await a.domain.focusSessionDao.setCurrentTask(
        sessionId: sessionId, taskId: _id('offplan-1'), now: a.clock.asDateTime);
    a.clock.advance(60000);
    await a.domain.focusSessionDao.reviewAndCloseSession(
      sessionId: sessionId,
      dispositions: {planned: 'rollover', _id('offplan-1'): 'leave'},
      now: a.clock.asDateTime,
    );
    await workspace.syncAll();
    await expectTableConverges('focus_session_dispositions');
    final row = await b.domain
        .customSelect('SELECT id, disposition FROM focus_session_dispositions')
        .getSingle();
    expect(row.read<String>('id'),
        focusSessionDispositionIdFor(sessionId, _id('offplan-1')));
    expect(row.read<String>('disposition'), 'leave');
  });

  test('user_preferences round-trip through the DAO', () async {
    await a.domain.userPreferencesDao.set(_userId, 'theme', '"dark"');
    await workspace.syncAll();
    expect(await b.domain.userPreferencesDao.get(_userId, 'theme'), '"dark"');
    await expectTableConverges('user_preferences');
  });

  group('tombstones and dangling references', () {
    test('a hard-deleted Outcome never resurrects from a replayed op', () async {
      final id = await outcomeOnA();
      await workspace.syncAll();
      a.clock.advance(1000);
      await a.domain.todoDao.deleteOutcome(id);
      await workspace.syncAll();

      for (final device in [a, b]) {
        expect(await device.domain.todoDao.getTodo(id), isNull);
      }
      // Replay from zero: the tombstone is in the log, so it cannot revive.
      await b.client.resetCursorForReplay();
      await b.sync();
      expect(await b.domain.todoDao.getTodo(id), isNull);
    });

    test('a TimeLog outlives its hard-deleted Outcome and renders as elsewhere',
        () async {
      final id = await outcomeOnA();
      await a.domain.todoDao
          .setCurrentActionText(id, 'Draft', now: a.clock.asDateTime);
      await a.domain.timeLogDao
          .openLog(taskId: id, userId: _userId, now: a.clock.asDateTime);
      a.clock.advance(60000);
      await a.domain.timeLogDao.closeLog(taskId: id, now: a.clock.asDateTime);
      await workspace.syncAll();
      a.clock.advance(1000);
      await a.domain.todoDao.deleteOutcome(id);
      await workspace.syncAll();

      for (final device in [a, b]) {
        final log = await device.domain.select(device.domain.timeLogs).getSingle();
        // Time data is never destroyed: SET NULL on the Action, Outcome-grain
        // attribution kept, and the dangling `task_id` renders as *elsewhere*.
        expect(log.actionId, isNull);
        expect(log.taskId, id);
        expect(await device.domain.todoDao.getTodo(id), isNull);
      }
      await expectTableConverges('time_logs');
    });

    test('a junction arriving before its parent is held back, then resolves',
        () async {
      // B authors the Outcome while offline; A authors nothing about it. The
      // junction op therefore reaches A before its parent could — the projector
      // must not error, and the row must appear once the parent arrives.
      final id = await outcomeOnA();
      final tagId =
          await a.domain.tagDao.findOrCreateTag('errand', 'context', _userId);
      await workspace.syncAll();

      b.goOffline();
      await b.domain.tagDao.assignTag(id, tagId, _userId);
      b.goOnline();
      await workspace.syncAll();
      await expectTableConverges('todo_tags');
    });

    test('an unassigned junction stays gone and revives on re-assignment',
        () async {
      final id = await outcomeOnA();
      final tagId =
          await a.domain.tagDao.findOrCreateTag('errand', 'context', _userId);
      await a.domain.tagDao.assignTag(id, tagId, _userId);
      await workspace.syncAll();
      a.clock.advance(1000);
      await a.domain.todoDao.setPersonTagsForTodo(id, const {}, _userId);
      // Person-tag replacement leaves a context tag alone, so unassign directly.
      await a.domain.tagDao.merge(tagId, await a.domain.tagDao
          .findOrCreateTag('other', 'context', _userId));
      await workspace.syncAll();
      for (final device in [a, b]) {
        final rows = await device.domain
            .customSelect('SELECT tag_id FROM todo_tags')
            .get();
        expect(rows.map((r) => r.read<String>('tag_id')), isNot(contains(tagId)));
      }
      await expectTableConverges('todo_tags');

      // The revival half. The junction entity was tombstoned, so re-assigning
      // the same pair has to bring the row back on both devices rather than
      // losing to the tombstone. The merged-away tag row itself is gone — the
      // junction is dangling by the same tolerance the TimeLog case above
      // relies on, and it is the junction entity's revival being asserted.
      a.clock.advance(1000);
      await a.domain.tagDao.assignTag(id, tagId, _userId);
      await workspace.syncAll();
      for (final device in [a, b]) {
        final rows = await device.domain
            .customSelect('SELECT tag_id FROM todo_tags')
            .get();
        expect(rows.map((r) => r.read<String>('tag_id')), contains(tagId));
      }
      await expectTableConverges('todo_tags');
    });
  });

  test('reduced state is byte-identical across devices', () async {
    final id = await outcomeOnA();
    await a.domain.todoDao.applyRouting(id,
        to: RoutingKind.nextAction, actionText: 'Draft', now: a.clock.asDateTime);
    await workspace.syncAll();
    expect(
      await canonicalReducedState(b.database),
      await canonicalReducedState(a.database),
    );
  });
}
