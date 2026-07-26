import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' as ps;

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

/// Repair the `actions` table at startup, in the one way that can never destroy
/// Action-grain truth (ADR-0001 story 9, issue #479; ADR-0022).
///
/// A single pass, [convergeMultiCurrentActions]: the
/// 0..1-`current`-per-Outcome invariant is app-enforced, not indexed, so a
/// cross-device race can sync in two `current` rows, and this retires the losers
/// by the same deterministic winner rule the writers use
/// (`ActionDao._winnerFirst`) so every device collapses to the same row. It
/// reads `actions` and nothing else.
///
/// **The sweep reads no next-action cursor on `todos`, and must never read one
/// again.** The `next_action_text` column itself is gone (ADR-0024, issue
/// #525), so today the warning is enforced by the schema — but it is recorded
/// here because the hazard is the *shape*, not the column name: any Outcome-grain
/// mirror of the current Action's text, re-added under any name, re-arms it.
/// Three cursor-driven arms were deleted over the course of #479, and reviving
/// any of them re-arms a way to destroy the user's Actions:
///
/// * One overwrote a `current` Action's text and metadata from the cursor — it
///   reverts every Action-grain edit at the next launch.
/// * One retired *every* `current` Action whose Outcome had a blank cursor —
///   with no cursor written, that retires every current Action on the device,
///   and syncs the deletions everywhere. (Either would also strand a retired
///   Action's open `time_logs` row: the sweep runs no termination hook.)
/// * The last, **cursor adoption**, minted the deterministic-id `current` Action
///   for a live Outcome carrying a non-blank cursor and no `actions` rows at
///   all. It looked safe — mint-only, monotone, guarded on the Outcome having no
///   Action rows whatsoever — and it was not. `ActionDao.applyRemovePlannedAction`
///   is a hard `DELETE` (the Remove-vs-Abandon distinction #478 shipped), and it
///   is the only mutation that drives an Outcome's Action count to zero while
///   the `todos` row survives. So on any store whose cursor was populated during
///   the dual-write era, *demote the current Action, then remove the planned
///   row* leaves a live cursor over zero Action rows — and the next launch minted
///   the Action the user had just deleted, back as `current`, and synced it to
///   every device. Two taps.
///
/// Deleting adoption makes that resurrection impossible by construction rather
/// than patching around it, and leaves `applyRemovePlannedAction` a hard delete.
/// The accepted cost: an Outcome created on a pre-Action client and synced in
/// renders Actionless until the user gives it an Action. Every such Outcome that
/// carried a cursor already has its `current` Action from the server backfill
/// (Alembic 0028) — so what is unsurfaced is an Outcome nobody ever clarified,
/// not lost text.
///
/// The pass is clarification-neutral: it **never** stamps `last_clarified_at`
/// (ADR-0012 — never auto-stamp on drift). It is idempotent, so the steady state
/// is one read and no writes at all. It runs from [powerSyncInstanceProvider]
/// right after [migrateLocalInboxToCaptures], before any watcher exists, so it
/// needs no view-notify.
///
/// Returns the number of Action rows retired. A steady-state store returns 0.
Future<int> reconcileActionsAtStartup(ps.PowerSyncDatabase db) async {
  var repaired = 0;
  await db.writeTransaction((tx) async {
    repaired = await convergeMultiCurrentActions(
      query: (sql, args) => tx.getAll(sql, args),
      exec: (sql, args) => tx.execute(sql, args).then((_) {}),
    );
  });
  return repaired;
}

/// A transaction's read/write pair, the seam the sweep is expressed over so the
/// exact SQL that runs in production can also be driven against a real SQLite
/// database in tests (see `reconcile_actions_sweep_test.dart`) — PowerSync only
/// supplies the transaction.
typedef SweepQuery = Future<List<Map<String, Object?>>> Function(
    String, List<Object?>);
typedef SweepExec = Future<void> Function(String, List<Object?>);

/// **Cursor-free, permanent.** Retire the losers of any accidental
/// multi-`current` set, keeping the winner by greatest `COALESCE(updated_at,
/// created_at)`, tie-break smallest `id` — the same rule `ActionDao._winnerFirst`
/// applies on every write and every read, so all devices converge on one row.
///
/// This is a genuine Action-grain repair and has nothing to do with the legacy
/// cursor: it visits **any** Outcome holding more than one `current` row. It
/// used to ride a join against the cursor column, so a cursorless Outcome's race
/// went unrepaired forever; it now touches no `todos` column at all. Retire,
/// never delete — the ADR-0018 history chain is the point.
///
/// Convergence is repair, not clarification: it never stamps.
///
/// One read in the steady state: the `HAVING COUNT(*) > 1` subquery returns
/// nothing, so the outer query returns no rows and no write fires.
Future<int> convergeMultiCurrentActions({
  required SweepQuery query,
  required SweepExec exec,
  DateTime? now,
}) async {
  final tsIso = (now ?? DateTime.now()).toUtc().toIso8601String();
  var repaired = 0;

  // Winner-first *within* each Outcome, so per Outcome the first row is the
  // keeper and every further row is a loser. Rows for an Outcome arrive
  // contiguous, and insertion order into the grouping below is the convergence
  // order.
  //
  // `outcome_id IS NOT NULL` is belt-and-braces, and deliberately kept.
  // On-device `actions` is a PowerSync view over JSON and carries none of
  // Drift's NOT NULL constraints, so a **legacy locally-written** row can hold
  // a NULL `outcome_id`: an app version whose PowerSync schema predated the
  // column stores no such key, and `json_extract` yields NULL for it. A *peer*
  // cannot deliver one — `actions.outcome_id` is `nullable=False` on the
  // backend (`backend/app/todos/models.py`) and the bucket is
  // `SELECT * FROM actions WHERE user_id = bucket.user_id`, so the server
  // rejects the row before it could ever replicate. The `as String` read below
  // would throw on a NULL, inside the startup write transaction. Today the
  // `IN` subquery already excludes those rows for free (`NULL IN (...)` is
  // NULL, never true), so the clause changes no behaviour; it is here so the
  // guarantee survives a future rewrite of the subquery into a JOIN, where
  // three-valued logic would no longer save us.
  final contested = await query(
    '''
    SELECT a.outcome_id AS outcome_id, a.id AS action_id
    FROM actions a
    WHERE a.role = 'current'
      AND a.outcome_id IS NOT NULL
      AND a.outcome_id IN (
        SELECT outcome_id FROM actions
        WHERE role = 'current'
        GROUP BY outcome_id
        HAVING COUNT(*) > 1
      )
    ORDER BY a.outcome_id ASC,
             COALESCE(a.updated_at, a.created_at) DESC,
             a.id ASC
    ''',
    [],
  );

  final byOutcome = <String, List<Object?>>{};
  for (final row in contested) {
    (byOutcome[row['outcome_id'] as String] ??= []).add(row['action_id']);
  }

  for (final ids in byOutcome.values) {
    for (final loserId in ids.skip(1)) {
      await exec(
        "UPDATE actions SET role = 'superseded', updated_at = ? WHERE id = ?",
        [tsIso, loserId],
      );
      repaired++;
    }
  }

  return repaired;
}

final migrationServiceProvider = Provider<LocalDataMigrationService>(
  (ref) => LocalDataMigrationService(ref),
);
