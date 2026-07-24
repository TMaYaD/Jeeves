import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' as ps;

import '../database/daos/action_ids.dart';
import '../providers/powersync_provider.dart';
import '../providers/user_constants.dart' show kLocalUserId;

enum ConflictResolution { keepLocal, keepServer, merge }

class MigrationResult {
  const MigrationResult({
    required this.todosMigrated,
    required this.tagsMigrated,
  });
  final int todosMigrated;
  final int tagsMigrated;
}

class LocalDataMigrationService {
  const LocalDataMigrationService(this._ref);
  final Ref _ref;

  /// Whether any local-only records (user_id = 'local') exist across the
  /// migratable tables.  Used to decide if migration is needed — returning
  /// false lets callers short-circuit before prompting for conflict resolution.
  Future<bool> hasLocalData() async {
    final db = await _ref.read(powerSyncInstanceProvider.future);
    const tables = [
      'todos',
      'tags',
      'todo_tags',
      'user_preferences',
      'captures',
      'capture_outcomes',
      'capture_tags',
      'actions',
    ];
    for (final table in tables) {
      final rows = await db.getAll(
        'SELECT COUNT(*) AS c FROM $table WHERE user_id = ?',
        ['local'],
      );
      final count = (rows.first['c'] as int?) ?? 0;
      if (count > 0) return true;
    }
    return false;
  }

  /// Reassign all records owned by [fromUserId] to [toUserId] in a single
  /// transaction.  PowerSync's CRUD queue captures these UPDATE operations and
  /// uploads them to the backend when the connection is established.
  ///
  /// For `user_preferences`, a LWW (last-write-wins) upsert is applied: when
  /// the target already has a row for the same key (e.g. another device synced
  /// a value while this device was offline), the row with the more recent
  /// `updated_at` is kept. Non-conflicting local rows are inserted under
  /// [toUserId]. After the upsert, all [fromUserId] rows are deleted.
  Future<MigrationResult> migrate({
    required String fromUserId,
    required String toUserId,
  }) async {
    final db = await _ref.read(powerSyncInstanceProvider.future);

    int todosMigrated = 0;
    int tagsMigrated = 0;

    await db.writeTransaction((tx) async {
      final todoRows = await tx
          .getAll('SELECT COUNT(*) AS c FROM todos WHERE user_id = ?', [fromUserId]);
      todosMigrated = (todoRows.first['c'] as int?) ?? 0;

      final tagRows = await tx
          .getAll('SELECT COUNT(*) AS c FROM tags WHERE user_id = ?', [fromUserId]);
      tagsMigrated = (tagRows.first['c'] as int?) ?? 0;

      await tx.execute(
        'UPDATE todos SET user_id = ? WHERE user_id = ?',
        [toUserId, fromUserId],
      );
      await tx.execute(
        'UPDATE tags SET user_id = ? WHERE user_id = ?',
        [toUserId, fromUserId],
      );
      await tx.execute(
        'UPDATE todo_tags SET user_id = ? WHERE user_id = ?',
        [toUserId, fromUserId],
      );

      // Capture/Outcome tables (issue #184). Plain reassignment, like
      // todos/tags/todo_tags — no LWW arbitration (only user_preferences is
      // keyed by a cross-device unique (user_id, key) that can collide).
      await tx.execute(
        'UPDATE captures SET user_id = ? WHERE user_id = ?',
        [toUserId, fromUserId],
      );
      await tx.execute(
        'UPDATE capture_outcomes SET user_id = ? WHERE user_id = ?',
        [toUserId, fromUserId],
      );
      await tx.execute(
        'UPDATE capture_tags SET user_id = ? WHERE user_id = ?',
        [toUserId, fromUserId],
      );

      // Actions (issue #471). Plain reassignment like todos/captures — adopted
      // local backfill rows re-key to the signed-in user before their queued
      // PUTs upload, so the Outcome-ownership check on POST /actions/ passes.
      await tx.execute(
        'UPDATE actions SET user_id = ? WHERE user_id = ?',
        [toUserId, fromUserId],
      );

      // Step 1: reassign non-conflicting rows (no matching key under toUserId).
      // Reuses the existing id to keep PowerSync's CRUD queue stable.
      await tx.execute(
        '''
        UPDATE user_preferences
        SET user_id = ?
        WHERE user_id = ?
          AND "key" NOT IN (
            SELECT "key" FROM user_preferences WHERE user_id = ?
          )
        ''',
        [toUserId, fromUserId, toUserId],
      );

      // Step 2: LWW for conflicting keys — update toUserId row when fromUserId
      // row is newer; leave it untouched otherwise. COALESCE guards against
      // NULL updated_at (shouldn't occur given the NOT NULL constraint, but
      // defensive in case of legacy rows).
      await tx.execute(
        '''
        UPDATE user_preferences
        SET value = (
          SELECT src.value FROM user_preferences src
          WHERE src.user_id = ? AND src."key" = user_preferences."key"
        ),
        updated_at = (
          SELECT src.updated_at FROM user_preferences src
          WHERE src.user_id = ? AND src."key" = user_preferences."key"
        )
        WHERE user_id = ?
          AND EXISTS (
            SELECT 1 FROM user_preferences src
            WHERE src.user_id = ?
              AND src."key" = user_preferences."key"
              AND COALESCE(src.updated_at, '1970-01-01T00:00:00.000Z')
                > COALESCE(user_preferences.updated_at, '1970-01-01T00:00:00.000Z')
          )
        ''',
        [fromUserId, fromUserId, toUserId, fromUserId],
      );

      // Step 3: remove all remaining fromUserId rows (conflicts resolved above).
      await tx.execute(
        'DELETE FROM user_preferences WHERE user_id = ?',
        [fromUserId],
      );
    });

    return MigrationResult(
      todosMigrated: todosMigrated,
      tagsMigrated: tagsMigrated,
    );
  }

  /// See [migrateLocalInboxToCaptures]. Convenience wrapper for callers that
  /// already hold a [Ref] rather than the database.
  Future<int> migrateLocalInbox({String userId = kLocalUserId}) async =>
      migrateLocalInboxToCaptures(
        await _ref.read(powerSyncInstanceProvider.future),
        userId: userId,
      );

  /// Delete all records owned by [userId] — used when the user chooses to
  /// discard local data in favour of their existing synced data.
  Future<void> deleteLocalData(String userId) async {
    final db = await _ref.read(powerSyncInstanceProvider.future);
    await db.writeTransaction((tx) async {
      // Child/junction rows first so FK-enforced deletes never fail.
      await tx.execute('DELETE FROM capture_tags WHERE user_id = ?', [userId]);
      await tx.execute('DELETE FROM capture_outcomes WHERE user_id = ?', [userId]);
      await tx.execute('DELETE FROM captures WHERE user_id = ?', [userId]);
      // Actions before todos (actions.outcome_id → todos.id). Skipping this
      // would orphan actions rows whose queued PUTs then 404 on the Outcome
      // ownership check and dead-letter → sync-error badge (issue #471).
      await tx.execute('DELETE FROM actions WHERE user_id = ?', [userId]);
      await tx.execute('DELETE FROM todo_tags WHERE user_id = ?', [userId]);
      await tx.execute('DELETE FROM tags WHERE user_id = ?', [userId]);
      await tx.execute('DELETE FROM todos WHERE user_id = ?', [userId]);
      await tx.execute('DELETE FROM user_preferences WHERE user_id = ?', [userId]);
    });
  }
}

/// Move local unclarified `todos` into `captures`, mirroring server-side
/// Alembic migration 0026 for users who have never signed in.
///
/// A signed-in user's Inbox is carved out server-side by 0026 and arrives via
/// sync. A local-only user has no server, so without this their Inbox — every
/// `todos` row with `clarified = false` — would simply vanish the moment the
/// UI started reading `captures` (issue #184 Phase 2).
///
/// Non-destructive and insert-before-delete, per AGENTS.md:
///
/// 1. Insert a Capture for each unclarified todo, reusing its id so any
///    reference to it stays valid.
/// 2. Copy that todo's `todo_tags` into `capture_tags` as tag *hints* —
///    **before** anything is removed, so a failure between steps leaves the
///    originals intact rather than orphaning the links.
/// 3. Only then delete the migrated `todos` / `todo_tags` rows.
///
/// Idempotent: the Capture insert is `INSERT OR IGNORE` and the tag copy is
/// keyed on the deterministic junction id, so a retry after a partial run
/// finishes it — copying any tags still missing and clearing the leftover
/// original — instead of duplicating or stranding it. Returns the number of
/// todos moved out of `todos`.
///
/// Takes the database directly rather than a [Ref] so it can run from inside
/// [powerSyncInstanceProvider], before anything reads the Inbox.
Future<int> migrateLocalInboxToCaptures(
  ps.PowerSyncDatabase db, {
  String userId = kLocalUserId,
}) async {
  var migrated = 0;
  await db.writeTransaction((tx) async {
    migrated = await carveOutLocalInbox(
      query: (sql, args) => tx.getAll(sql, args),
      exec: (sql, args) => tx.execute(sql, args).then((_) {}),
      userId: userId,
    );
  });
  return migrated;
}

/// The carve-out itself, expressed over a transaction's read/write pair.
///
/// Split out from [migrateLocalInboxToCaptures] so the exact SQL that runs in
/// production can also be driven against a real SQLite database in tests
/// (see `migrate_local_inbox_test.dart`) rather than a stand-in — PowerSync
/// only supplies the transaction, and the statements are what matter.
///
/// Callers must already be inside a write transaction: the steps below are
/// only safe together.
Future<int> carveOutLocalInbox({
  required Future<List<Map<String, Object?>>> Function(String, List<Object?>)
      query,
  required Future<void> Function(String, List<Object?>) exec,
  String userId = kLocalUserId,
}) async {
  // Every eligible todo, including any whose Capture already exists: a
  // NOT EXISTS guard here would permanently strand a half-carved row — its
  // tags never copied and the original never deleted — leaving the item in
  // both halves of the split forever. Re-processing one is harmless because
  // each step below is individually idempotent.
  final pending = await query(
    '''
    SELECT id, title, notes, capture_source, created_at, updated_at
    FROM todos
    WHERE user_id = ? AND clarified = 0
    ''',
    [userId],
  );
  if (pending.isEmpty) return 0;

  for (final row in pending) {
    // Step 1: the Capture. `clarified_at` stays NULL — these rows were in the
    // Inbox and must still be after the move.
    await exec(
      '''
      INSERT OR IGNORE INTO captures
        (id, title, notes, capture_source, created_at, clarified_at,
         updated_at, user_id)
      VALUES (?, ?, ?, ?, ?, NULL, ?, ?)
      ''',
      [
        row['id'],
        row['title'],
        row['notes'],
        row['capture_source'],
        row['created_at'],
        row['updated_at'],
        userId,
      ],
    );

    // Step 2: its tags become tag hints. Done before any delete so a failure
    // here cannot strand a Capture without its links.
    await exec(
      '''
      INSERT OR IGNORE INTO capture_tags (id, capture_id, tag_id, user_id)
      SELECT id, todo_id, tag_id, user_id
      FROM todo_tags WHERE todo_id = ?
      ''',
      [row['id']],
    );
  }

  // Step 3: the originals, now fully copied. Junction rows first so the delete
  // never trips foreign-key enforcement.
  final ids = [for (final r in pending) r['id']];
  final placeholders = List.filled(ids.length, '?').join(', ');
  await exec('DELETE FROM todo_tags WHERE todo_id IN ($placeholders)', ids);
  await exec('DELETE FROM todos WHERE id IN ($placeholders)', ids);

  return pending.length;
}

/// Reconcile the `actions` table against the authoritative next-action cursor
/// (`todos.next_action_text` + the `energy_level` / `time_estimate` cursor
/// fields), discharging the #471 backfill drift obligation and repairing the
/// ongoing old-client replay window (ADR-0001 story 2, issue #472).
///
/// The #471 backfill was a one-time snapshot: every cursor edit after it — and
/// every `PATCH todos.next_action_text` an old app version replays during the
/// dual-write rollout — strands the Action row in one of three drift modes.
/// This sweep repairs them, always in the direction **cursor → actions** (the
/// cursor stays authoritative for reads until story 3). It is a
/// clarification-neutral repair: it **never** stamps `last_clarified_at`
/// (ADR-0012 spirit — never auto-stamp on drift), and it is idempotent and safe
/// on every launch. Runs from [powerSyncInstanceProvider] right after
/// [migrateLocalInboxToCaptures], before any watcher exists, so — like the v26
/// backfill — it needs no view-notify.
Future<int> reconcileActionsWithCursor(ps.PowerSyncDatabase db) async {
  var repaired = 0;
  await db.writeTransaction((tx) async {
    repaired = await reconcileActionsWithCursorSteps(
      query: (sql, args) => tx.getAll(sql, args),
      exec: (sql, args) => tx.execute(sql, args).then((_) {}),
    );
  });
  return repaired;
}

/// The reconciliation itself, expressed over a transaction's read/write pair so
/// the exact SQL can be driven against a real SQLite database in tests (see
/// `reconcile_actions_sweep_test.dart`) — PowerSync only supplies the
/// transaction. Callers must already be inside a write transaction.
///
/// Returns the number of Action rows written (minted, updated, resurrected, or
/// retired) — used only as a signal in tests.
Future<int> reconcileActionsWithCursorSteps({
  required Future<List<Map<String, Object?>>> Function(String, List<Object?>)
      query,
  required Future<void> Function(String, List<Object?>) exec,
  DateTime? now,
}) async {
  final ts = (now ?? DateTime.now()).toUtc();
  final tsIso = ts.toIso8601String();
  var repaired = 0;

  // Pass A — outcomes with a live cursor: mint / update / resurrect so exactly
  // one `current` Action matches the cursor.
  final withCursor = await query(
    '''
    SELECT id, user_id, next_action_text, energy_level, time_estimate
    FROM todos
    WHERE next_action_text IS NOT NULL AND TRIM(next_action_text) != ''
    ''',
    [],
  );
  for (final row in withCursor) {
    final outcomeId = row['id'] as String;
    final cursorText = row['next_action_text'] as String;
    final energy = row['energy_level'];
    final time = row['time_estimate'];
    final userId = row['user_id'] as String;

    // Current rows, winner-first (greatest COALESCE(updated_at, created_at),
    // tie-break smallest id) so index 0 is the keeper on convergence.
    final currents = await query(
      '''
      SELECT id, text, energy_level, time_estimate
      FROM actions
      WHERE outcome_id = ? AND role = 'current'
      ORDER BY COALESCE(updated_at, created_at) DESC, id ASC
      ''',
      [outcomeId],
    );

    if (currents.isNotEmpty) {
      // Converge any accidental multi-current set: retire all but the winner.
      for (final loser in currents.skip(1)) {
        await exec(
          "UPDATE actions SET role = 'superseded', updated_at = ? WHERE id = ?",
          [tsIso, loser['id']],
        );
        repaired++;
      }
      final keeper = currents.first;
      // Mode 1 — stale row: bring text + metadata in line with the cursor.
      final differs = keeper['text'] != cursorText ||
          keeper['energy_level'] != energy ||
          keeper['time_estimate'] != time;
      if (differs) {
        await exec(
          "UPDATE actions "
          "SET text = ?, energy_level = ?, time_estimate = ?, updated_at = ? "
          "WHERE id = ?",
          [cursorText, energy, time, tsIso, keeper['id']],
        );
        repaired++;
      }
      continue;
    }

    // Mode 3 — missing row: mint or resurrect via the deterministic backfill id
    // so independent devices converge on one row (ADR-0019 + ADR-0015 upsert).
    final detId = backfillActionIdFor(outcomeId);
    final detRows = await query('SELECT role FROM actions WHERE id = ?', [detId]);
    if (detRows.isEmpty) {
      await exec(
        "INSERT INTO actions "
        "(id, outcome_id, user_id, text, role, energy_level, time_estimate, "
        "created_at, updated_at) "
        "VALUES (?, ?, ?, ?, 'current', ?, ?, ?, ?)",
        [detId, outcomeId, userId, cursorText, energy, time, tsIso, tsIso],
      );
      repaired++;
    } else if (detRows.first['role'] == 'superseded') {
      // Resurrect the deterministic row — guarded on `superseded` so a future
      // `done` row can never be revived. This also self-heals the transient
      // both-superseded convergence race (two devices mutually retire under
      // sync lag, leaving the outcome currentless while the cursor still holds
      // text): the next startup sweep flips the deterministic row back.
      await exec(
        "UPDATE actions "
        "SET role = 'current', text = ?, energy_level = ?, time_estimate = ?, "
        "updated_at = ? "
        "WHERE id = ? AND role = 'superseded'",
        [cursorText, energy, time, tsIso, detId],
      );
      repaired++;
    } else {
      // The deterministic slot is held by a non-superseded (`done`) row —
      // completion semantics are story 4. Honour the cursor with a fresh-id
      // current row; cross-device convergence collapses any duplicates later
      // via the winner rule. (Unreachable in story 2: nothing writes `done`.)
      await exec(
        "INSERT INTO actions "
        "(id, outcome_id, user_id, text, role, energy_level, time_estimate, "
        "created_at, updated_at) "
        "VALUES (?, ?, ?, ?, 'current', ?, ?, ?, ?)",
        [ps.uuid.v4(), outcomeId, userId, cursorText, energy, time, tsIso, tsIso],
      );
      repaired++;
    }
  }

  // Pass B — mode 2 phantom rows: cursor blank/NULL but a `current` Action
  // survives. Retire (not delete): preserve the ADR-0018 history chain — a
  // clear was semantically an abandon.
  final phantoms = await query(
    '''
    SELECT a.id AS action_id
    FROM actions a
    JOIN todos t ON t.id = a.outcome_id
    WHERE a.role = 'current'
      AND (t.next_action_text IS NULL OR TRIM(t.next_action_text) = '')
    ''',
    [],
  );
  for (final p in phantoms) {
    await exec(
      "UPDATE actions SET role = 'superseded', updated_at = ? WHERE id = ?",
      [tsIso, p['action_id']],
    );
    repaired++;
  }

  return repaired;
}

final migrationServiceProvider = Provider<LocalDataMigrationService>(
  (ref) => LocalDataMigrationService(ref),
);
