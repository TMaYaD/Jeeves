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

/// Repair the `actions` table at startup, in the only two ways that can never
/// destroy Action-grain truth (ADR-0001 story 9, issue #479).
///
/// The sweep is deliberately **monotone**: across a run, `COUNT(*) FROM
/// actions` never decreases and no existing row's `text` is ever rewritten. It
/// does exactly two things, in order:
///
/// 1. [convergeMultiCurrentActions] — **cursor-free and permanent.** The
///    0..1-`current`-per-Outcome invariant is app-enforced, not indexed, so a
///    cross-device race can sync in two `current` rows. This pass retires the
///    losers by the same deterministic winner rule the writers use
///    (`ActionDao._winnerFirst`), so every device collapses to the same row.
/// 2. [adoptCursorsWithoutActions] — **cursor-dependent, mint-only.** Mints the
///    deterministic-id `current` Action (ADR-0019) for an Outcome carrying a
///    non-blank legacy `todos.next_action_text` cursor **and no `actions` rows
///    at all**. This is the last thing the cursor is still good for: adopting
///    an Outcome that a pre-Action client created and this device has never
///    seen an Action for. It dies with the columns.
///
/// **Two earlier arms were deleted, and must not come back.** The sweep used to
/// treat the cursor as authoritative: one arm overwrote a `current` Action's
/// text and metadata from the cursor, and another retired *every* `current`
/// Action whose Outcome had a blank cursor. Both were consistent only for as
/// long as every write path dual-wrote the cursor; the moment the cursor stops
/// being written they become weapons — the first reverts every Action edit at
/// the next launch, the second retires every current Action on the device.
/// Reviving either would also re-introduce the hazard that a sweep-retired
/// Action strands its open `time_logs` row (the sweep runs no termination hook).
///
/// The adoption pass never overwrites and never retires, which is what makes it
/// safe to keep: it cannot resurrect an Action the user abandoned, and it cannot
/// revert an edit. The deliberate cost is that a cursor edit arriving from a
/// pre-retirement client is silently ignored on an Outcome that already has
/// Action rows — losing a stale client's edit is preferred to letting it clobber
/// Action-grain history.
///
/// Both passes are clarification-neutral: they **never** stamp
/// `last_clarified_at` (ADR-0012 — never auto-stamp on drift). The whole sweep
/// is idempotent, so the steady state is two reads and no writes at all. It runs
/// from [powerSyncInstanceProvider] right after [migrateLocalInboxToCaptures],
/// before any watcher exists, so — like the v26 backfill — it needs no
/// view-notify.
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

/// A transaction's read/write pair, the seam every sweep pass is expressed over
/// so the exact SQL that runs in production can also be driven against a real
/// SQLite database in tests (see `reconcile_actions_sweep_test.dart`) —
/// PowerSync only supplies the transaction.
typedef SweepQuery = Future<List<Map<String, Object?>>> Function(
    String, List<Object?>);
typedef SweepExec = Future<void> Function(String, List<Object?>);

/// Both passes, in order. Callers must already be inside a write transaction.
///
/// Returns the number of Action rows written (minted or retired) — used only as
/// a signal in tests. A steady-state store returns 0.
Future<int> reconcileActionsWithCursorSteps({
  required SweepQuery query,
  required SweepExec exec,
  DateTime? now,
}) async {
  final ts = (now ?? DateTime.now()).toUtc();
  // Convergence first: adoption only mints into an Outcome with no `actions`
  // rows at all, so the order is not load-bearing — but leaving a multi-current
  // set standing while another pass runs would make the run's reported count
  // depend on interleaving.
  return await convergeMultiCurrentActions(
        query: query,
        exec: exec,
        now: ts,
      ) +
      await adoptCursorsWithoutActions(query: query, exec: exec, now: ts);
}

/// **Cursor-free, permanent.** Retire the losers of any accidental
/// multi-`current` set, keeping the winner by greatest `COALESCE(updated_at,
/// created_at)`, tie-break smallest `id` — the same rule `ActionDao._winnerFirst`
/// applies on every write and every read, so all devices converge on one row.
///
/// This is a genuine Action-grain repair and has nothing to do with the legacy
/// cursor: it visits **any** Outcome holding more than one `current` row,
/// whatever `todos.next_action_text` says (it used to ride the cursor join, so
/// a cursorless Outcome's race went unrepaired forever). Retire, never delete —
/// the ADR-0018 history chain is the point.
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
  final contested = await query(
    '''
    SELECT a.outcome_id AS outcome_id, a.id AS action_id
    FROM actions a
    WHERE a.role = 'current'
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

/// **Cursor-dependent, mint-only, monotone.** Mint the deterministic-id
/// `current` Action for every Outcome that carries a non-blank legacy
/// `todos.next_action_text` **and has no `actions` rows at all**.
///
/// The `NOT EXISTS` guard is over *all* roles, not just `current`: an Outcome
/// holding a `superseded`, `done` or `planned` row has already been spoken for
/// at the Action grain, and the cursor has nothing to add. That guard is the
/// whole safety property — it means this pass can never resurrect an abandoned
/// Action, never revive a completed one, and never overwrite or retire anything.
/// The cost is deliberate: an Outcome whose only Action was completed on another
/// device will not regrow one here from a stale cursor.
///
/// The id is `backfillActionIdFor(outcomeId)` (ADR-0019), the same value the
/// server's Alembic 0028 and every client's Drift v26 backfill compute, so two
/// devices adopting the same Outcome independently upsert onto one row
/// (ADR-0015) instead of minting divergent random-id `current` rows that would
/// break the 0..1-current invariant on sync.
///
/// Energy / time come from the Outcome's draft columns, matching what
/// `ActionDao.applySetCurrentAction` seeds into a birth Action (D3). Never
/// stamps `last_clarified_at` — adopting a straggler's cursor is not a
/// clarifying act (ADR-0012).
Future<int> adoptCursorsWithoutActions({
  required SweepQuery query,
  required SweepExec exec,
  DateTime? now,
}) async {
  final tsIso = (now ?? DateTime.now()).toUtc().toIso8601String();
  var repaired = 0;

  // One statement: every Outcome whose cursor still says something and whose
  // Action-grain history is entirely empty. The `NOT EXISTS` over *all* roles is
  // the safety guard (see the doc comment). Blank / whitespace-only cursors are
  // Actionless by the app's own normalisation and mint nothing. In the steady
  // state this is one read and no writes.
  final orphanCursors = await query(
    '''
    SELECT t.id AS outcome_id, t.user_id AS user_id,
           t.next_action_text AS cursor_text,
           t.energy_level AS cursor_energy,
           t.time_estimate AS cursor_time
    FROM todos t
    WHERE t.next_action_text IS NOT NULL
      AND TRIM(t.next_action_text) != ''
      AND NOT EXISTS (
        SELECT 1 FROM actions a WHERE a.outcome_id = t.id
      )
    ORDER BY t.id ASC
    ''',
    [],
  );

  for (final row in orphanCursors) {
    final outcomeId = row['outcome_id'] as String;
    await exec(
      "INSERT INTO actions "
      "(id, outcome_id, user_id, text, role, energy_level, time_estimate, "
      "created_at, updated_at) "
      "VALUES (?, ?, ?, ?, 'current', ?, ?, ?, ?)",
      [
        backfillActionIdFor(outcomeId),
        outcomeId,
        row['user_id'] as String,
        row['cursor_text'],
        row['cursor_energy'],
        row['cursor_time'],
        tsIso,
        tsIso,
      ],
    );
    repaired++;
  }

  return repaired;
}

final migrationServiceProvider = Provider<LocalDataMigrationService>(
  (ref) => LocalDataMigrationService(ref),
);
