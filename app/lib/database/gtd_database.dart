/// Local-first GTD database backed by Drift.
///
/// Accepts any Drift [QueryExecutor] so the same class serves both
/// production (a `SqliteAsyncDriftConnection` over PowerSync's shared
/// SQLite file, typically wrapped in `DatabaseConnection.delayed`) and
/// tests (`NativeDatabase.memory()`).
///
/// Schema ownership: on production PowerSync owns the application-visible
/// `todos` / `tags` / `todo_tags` as views over its internal `ps_data__*`
/// tables, so schema changes there are driven by [powersyncSchema], not by
/// Drift's migrator — `ALTER TABLE` on a view throws SQLITE_ERROR.  The
/// [_addColumnIfTable] helper short-circuits `addColumn` when the target is
/// a view so upgrades are a true no-op on the production path while still
/// running against real tables under `NativeDatabase.memory()` in tests.
library;

import 'package:drift/drift.dart';
import 'package:powersync/powersync.dart' show uuid;

import 'daos/action_dao.dart';
import 'daos/capture_dao.dart';
import 'daos/focus_session_dao.dart';
import 'daos/search_dao.dart';
import 'daos/tag_dao.dart';
import 'daos/time_log_dao.dart';
import 'daos/todo_dao.dart';
import 'daos/user_preferences_dao.dart';
import 'tables.dart';

export 'tables.dart';

part 'gtd_database.g.dart';

@DriftDatabase(
  tables: [Todos, Tags, TodoTags, TimeLogs, FocusSessions, FocusSessionTasks, FocusSessionDispositions, UserPreferences, SyncDeadLetters, Captures, CaptureOutcomes, CaptureTags, Actions],
  daos: [TagDao, TodoDao, TimeLogDao, FocusSessionDao, CaptureDao, ActionDao],
)
class GtdDatabase extends _$GtdDatabase {
  GtdDatabase(super.executor);

  /// Plain-class DAO for universal search (no code generation required).
  late final SearchDao searchDao = SearchDao(this);

  /// DAO for synced key-value user preferences.
  late final UserPreferencesDao userPreferencesDao = UserPreferencesDao(this);

  @override
  int get schemaVersion => 28;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await _addColumnIfTable(m, todos, todos.timeSpentMinutes);
            // in_progress_since existed from v2 to v13; add it here so the
            // v1→v14 upgrade path is consistent, then drop it in the v14 step.
            final todosInfo = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todos'",
            ).get();
            if (todosInfo.isNotEmpty &&
                todosInfo.first.read<String>('type') == 'table') {
              await customStatement(
                'ALTER TABLE todos ADD COLUMN in_progress_since TEXT',
              );
              // blocked_by_todo_id existed from v2 to v7.
              await customStatement(
                'ALTER TABLE todos ADD COLUMN blocked_by_todo_id TEXT',
              );
            }
          }
          if (from < 3) {
            // selected_for_today and daily_selection_date existed v3–v13.
            final todosInfo = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todos'",
            ).get();
            if (todosInfo.isNotEmpty &&
                todosInfo.first.read<String>('type') == 'table') {
              await customStatement(
                'ALTER TABLE todos ADD COLUMN selected_for_today INTEGER',
              );
              await customStatement(
                'ALTER TABLE todos ADD COLUMN daily_selection_date TEXT',
              );
            }
          }
          if (from < 4) {
            // waiting_for was added in v4 and dropped in v19.
            // Use raw SQL because the Drift accessor was removed in schema v19.
            final todosRows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todos'",
            ).get();
            if (todosRows.isNotEmpty &&
                todosRows.first.read<String>('type') == 'table') {
              final cols =
                  await customSelect('PRAGMA table_info(todos)').get();
              if (!cols.any((r) => r.read<String>('name') == 'waiting_for')) {
                await customStatement(
                  'ALTER TABLE todos ADD COLUMN waiting_for TEXT',
                );
              }
            }
          }
          if (from < 5) {
            await _addColumnIfTable(m, todoTags, todoTags.userId);
          }
          if (from < 6) {
            // todoTags.id is declared non-nullable, so m.addColumn generates
            // ALTER TABLE ... ADD COLUMN id TEXT NOT NULL, which SQLite rejects
            // on populated tables (no DEFAULT clause).  Add as nullable first,
            // backfill, then the invariant is satisfied without a table rebuild.
            // _addColumnIfTable is not used here because it delegates to
            // m.addColumn which would emit the NOT NULL form.
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todo_tags'",
            ).get();
            if (rows.isNotEmpty && rows.first.read<String>('type') == 'table') {
              await customStatement('ALTER TABLE todo_tags ADD COLUMN id TEXT');
              await customStatement(
                "UPDATE todo_tags SET id = lower(hex(randomblob(16))) "
                "WHERE id IS NULL",
              );
            }
          }
          if (from < 7) {
            // Backfill derived colors for tags created before per-tag color
            // storage was introduced.  Running this as a migration rather than
            // on every startup means a later updateColor(tagId, null) that
            // intentionally clears a color is never overwritten.
            await tagDao.backfillAllMissingColors();
          }
          if (from < 8) {
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todos'",
            ).get();
            if (rows.isNotEmpty && rows.first.read<String>('type') == 'table') {
              final cols =
                  await customSelect('PRAGMA table_info(todos)').get();
              final hasCol = cols.any(
                (r) => r.read<String>('name') == 'blocked_by_todo_id',
              );
              if (hasCol) {
                await customStatement(
                  'ALTER TABLE todos DROP COLUMN blocked_by_todo_id',
                );
              }
            }
          }
          if (from < 9) {
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'time_logs'",
            ).get();
            // Only create the real table when it doesn't exist yet.
            // On production PowerSync will have already created a view named
            // 'time_logs' from powersyncSchema — calling createTable on a
            // view would fail.  When rows is empty the object doesn't exist
            // at all (NativeDatabase test path), so we create it.
            if (rows.isEmpty) {
              await m.createTable(timeLogs);
            }
          }
          if (from < 10) {
            final todosInfo = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todos'",
            ).get();
            if (todosInfo.isNotEmpty &&
                todosInfo.first.read<String>('type') == 'table') {
              final cols =
                  await customSelect('PRAGMA table_info(todos)').get();
              final hasIntent =
                  cols.any((r) => r.read<String>('name') == 'intent');
              if (!hasIntent) {
                await customStatement(
                  "ALTER TABLE todos ADD COLUMN intent TEXT NOT NULL DEFAULT 'next'",
                );
              }
              final hasStateV10 =
                  cols.any((r) => r.read<String>('name') == 'state');
              if (hasStateV10) {
                await customStatement(
                  "UPDATE todos SET intent = 'maybe', state = 'next_action' "
                  "WHERE state = 'someday_maybe'",
                );
              }
            }
          }
          if (from < 11) {
            // Guard: only ADD COLUMN if todos table exists and clarified column doesn't.
            final tables = await customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='todos'",
            ).get();
            if (tables.isNotEmpty) {
              final cols = await customSelect("PRAGMA table_info(todos)").get();
              final hasClarified =
                  cols.any((r) => r.read<String>('name') == 'clarified');
              if (!hasClarified) {
                await customStatement(
                  "ALTER TABLE todos ADD COLUMN clarified INTEGER NOT NULL DEFAULT 1",
                );
              }
              // Normalize legacy inbox rows (state column exists until v15).
              final hasStateV11 =
                  cols.any((r) => r.read<String>('name') == 'state');
              if (hasStateV11) {
                await customStatement(
                  "UPDATE todos SET clarified = 0, state = 'next_action' WHERE state = 'inbox'",
                );
              }
            }
          }
          if (from < 12) {
            final tables = await customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='todos'",
            ).get();
            if (tables.isNotEmpty) {
              final cols = await customSelect("PRAGMA table_info(todos)").get();
              final hasDoneAt =
                  cols.any((r) => r.read<String>('name') == 'done_at');
              if (!hasDoneAt) {
                await customStatement(
                  'ALTER TABLE todos ADD COLUMN done_at TEXT',
                );
              }
              // Backfill done_at only for rows where it is not already set.
              // Mirror the Postgres backfill: also cover rows where completed=1
              // but state diverged (nothing enforced co-setting of both fields).
              final hasStateV12 =
                  cols.any((r) => r.read<String>('name') == 'state');
              final hasCompleted =
                  cols.any((r) => r.read<String>('name') == 'completed');
              if (hasStateV12) {
                if (hasCompleted) {
                  await customStatement(
                    "UPDATE todos "
                    "SET done_at = COALESCE(done_at, updated_at) "
                    "WHERE (state = 'done' OR completed = 1) AND done_at IS NULL",
                  );
                } else {
                  await customStatement(
                    "UPDATE todos "
                    "SET done_at = COALESCE(done_at, updated_at) "
                    "WHERE state = 'done' AND done_at IS NULL",
                  );
                }
                await customStatement(
                  "UPDATE todos SET state = 'next_action' WHERE state = 'done'",
                );
              } else if (hasCompleted) {
                await customStatement(
                  "UPDATE todos "
                  "SET done_at = COALESCE(done_at, updated_at) "
                  "WHERE completed = 1 AND done_at IS NULL",
                );
              }
              // completed column: intentionally NOT dropped — SQLite DROP COLUMN
              // is unreliable across OS versions; Drift treats it as invisible.
            }
          }
          if (from < 13) {
            // Collapse legacy waiting_for state rows before PowerSync re-syncs
            // the rewritten rows from Postgres (state column dropped in v15).
            final v13Cols =
                await customSelect('PRAGMA table_info(todos)').get();
            if (v13Cols.any((r) => r.read<String>('name') == 'state')) {
              await customStatement(
                "UPDATE todos SET state = 'next_action' WHERE state = 'waiting_for'",
              );
            }
          }
          if (from < 14) {
            // Create FocusSessions/FocusSessionTasks tables in test only;
            // PowerSync creates views from powersyncSchema in production.
            final fsRows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'focus_sessions'",
            ).get();
            if (fsRows.isEmpty) {
              await m.createTable(focusSessions);
            }
            final fstRows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'focus_session_tasks'",
            ).get();
            if (fstRows.isEmpty) {
              await m.createTable(focusSessionTasks);
            }

            // Add focus_session_id to time_logs (no-op on production view).
            await _addColumnIfTable(m, timeLogs, timeLogs.focusSessionId);

            // Drop retired columns from todos (no-op on production view).
            await _dropColumnIfTable('todos', 'in_progress_since');
            await _dropColumnIfTable('todos', 'selected_for_today');
            await _dropColumnIfTable('todos', 'daily_selection_date');

            // Collapse in_progress → next_action (state column dropped in v15).
            final v14Cols =
                await customSelect('PRAGMA table_info(todos)').get();
            if (v14Cols.any((r) => r.read<String>('name') == 'state')) {
              await customStatement(
                "UPDATE todos SET state = 'next_action' WHERE state = 'in_progress'",
              );
            }
          }
          if (from < 15) {
            // Drop the now-constant state column (all rows hold 'next_action').
            await _dropColumnIfTable('todos', 'state');
          }
          if (from < 16) {
            await _addColumnIfTable(
                m, focusSessionTasks, focusSessionTasks.disposition);
          }
          if (from < 17) {
            // Add PowerSync-required `id` column to focus_session_tasks.
            // In production this table is a PowerSync-managed view (id already
            // auto-injected by the trigger); this block only runs on real tables
            // (NativeDatabase path: tests and fresh local DBs).
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'focus_session_tasks'",
            ).get();
            if (rows.isNotEmpty &&
                rows.first.read<String>('type') == 'table') {
              final cols = await customSelect(
                'PRAGMA table_info(focus_session_tasks)',
              ).get();
              if (!cols.any((r) => r.read<String>('name') == 'id')) {
                // SQLite rejects NOT NULL ADD COLUMN without a DEFAULT on
                // populated tables; add as nullable, backfill, then enforce
                // uniqueness via index.
                await customStatement(
                  'ALTER TABLE focus_session_tasks ADD COLUMN id TEXT',
                );
                await customStatement(
                  'UPDATE focus_session_tasks '
                  "SET id = lower(hex(randomblob(16))) WHERE id IS NULL",
                );
                await customStatement(
                  'CREATE UNIQUE INDEX idx_fst_id '
                  'ON focus_session_tasks(id)',
                );
              }
            }
          }
          if (from < 18) {
            // Add UNIQUE index on todo_tags.id so PowerSync triggers can rely
            // on id uniqueness. In production todo_tags is a PowerSync-managed
            // view — SQLite forbids indexes on views, so only run on real tables.
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'todo_tags'",
            ).get();
            if (rows.isNotEmpty &&
                rows.first.read<String>('type') == 'table') {
              await customStatement(
                'CREATE UNIQUE INDEX IF NOT EXISTS '
                'idx_todo_tags_id ON todo_tags(id)',
              );
            }
          }
          if (from < 19) {
            // Add last_clarified_at; drop waiting_for (migration 0022).
            await _addColumnIfTable(m, todos, todos.lastClarifiedAt);
            await _dropColumnIfTable('todos', 'waiting_for');
          }
          if (from < 20) {
            // Create user_preferences table on NativeDatabase (test/local) path only.
            // On production PowerSync has already created a view named 'user_preferences',
            // so we skip creation when the name is already registered in sqlite_master.
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'user_preferences'",
            ).get();
            if (rows.isEmpty) {
              await m.createTable(userPreferences);
            }
          }
          if (from < 21) {
            // Add last_next_action_completion_at (issue #237). The sibling
            // next_action_text column this block also added is gone — the v28
            // block below drops it, so there is nothing to add here (ADR-0024).
            await _addColumnIfTable(m, todos, todos.lastNextActionCompletionAt);
          }
          if (from < 22) {
            // Add denormalized user_id to focus_session_tasks (issue #381) so
            // PowerSync can bucket junction rows per user without a JOIN.
            // In production this table is a PowerSync-managed view (the column
            // arrives via powersyncSchema); this block only runs on real tables
            // (NativeDatabase path: tests and fresh local DBs).
            // userId is declared non-nullable, so _addColumnIfTable would emit
            // ALTER TABLE ... ADD COLUMN user_id TEXT NOT NULL, which SQLite
            // rejects on populated tables (no DEFAULT clause) — add as nullable
            // via raw SQL and backfill from the parent session instead (same
            // approach as the v17 id column).
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'focus_session_tasks'",
            ).get();
            if (rows.isNotEmpty &&
                rows.first.read<String>('type') == 'table') {
              final cols = await customSelect(
                'PRAGMA table_info(focus_session_tasks)',
              ).get();
              if (!cols.any((r) => r.read<String>('name') == 'user_id')) {
                await customStatement(
                  'ALTER TABLE focus_session_tasks ADD COLUMN user_id TEXT',
                );
                await customStatement(
                  'UPDATE focus_session_tasks SET user_id = ('
                  '  SELECT fs.user_id FROM focus_sessions fs '
                  '  WHERE fs.id = focus_session_tasks.focus_session_id'
                  ') WHERE user_id IS NULL',
                );
              }
            }
          }
          if (from < 23) {
            // Local-only dead-letter table for non-retryable upload failures
            // (issue #305). Not a PowerSync view — plain CREATE TABLE is safe
            // on both the production and NativeDatabase paths.
            await m.createTable(syncDeadLetters);
          }
          if (from < 24) {
            // Capture/Outcome schema split (issue #184, ADR-0006). In
            // production PowerSync creates `captures` / `capture_outcomes` /
            // `capture_tags` as views from powersyncSchema, and the row-move
            // out of `todos` runs in the backend (Alembic 0026) and replicates
            // down — so only create the real tables on the NativeDatabase test
            // path, guarding on sqlite_master exactly like `time_logs`
            // (from < 9) and `user_preferences` (from < 20).
            final captureTables = <TableInfo<Table, dynamic>>[
              captures,
              captureOutcomes,
              captureTags,
            ];
            for (final table in captureTables) {
              final rows = await customSelect(
                "SELECT type FROM sqlite_master WHERE name = ?",
                variables: [Variable<String>(table.actualTableName)],
              ).get();
              if (rows.isEmpty) {
                await m.createTable(table);
              }
            }
          }
          if (from < 25) {
            // Off-Plan disposition store (issue #418, ADR-0016). In production
            // PowerSync creates `focus_session_dispositions` as a view from
            // powersyncSchema, and the row is filled by the client's local
            // write replicating up — so only create the real table on the
            // NativeDatabase test path, guarding on sqlite_master exactly like
            // `time_logs` (from < 9), `user_preferences` (from < 20), and the
            // Capture tables (from < 24).
            final rows = await customSelect(
              "SELECT type FROM sqlite_master "
              "WHERE name = 'focus_session_dispositions'",
            ).get();
            if (rows.isEmpty) {
              await m.createTable(focusSessionDispositions);
            }
          }
          if (from < 26) {
            // Actions table (issue #471, ADR-0001 story 1). In production
            // PowerSync creates `actions` as a view from powersyncSchema — so
            // only create the real table on the NativeDatabase test path,
            // guarding on sqlite_master exactly like the Capture tables
            // (from < 24) and focus_session_dispositions (from < 25).
            //
            // Table creation only: the client-side Action backfill that used to
            // run here read `todos.next_action_text`, which v28 drops. The
            // server backfill (Alembic 0028) already minted every one of those
            // Actions on the same deterministic uuid5 id, so a client reaching
            // v26 today re-syncs them rather than re-deriving them (ADR-0024).
            final rows = await customSelect(
              "SELECT type FROM sqlite_master WHERE name = 'actions'",
            ).get();
            if (rows.isEmpty) {
              await m.createTable(actions);
            }
          }
          if (from < 27) {
            // Action-grain TimeLog attribution (issue #476, ADR-0001 story 6):
            // a nullable `action_id` on time_logs. Additive and guarded by the
            // same view-safe pattern as focus_session_id (from < 14): a no-op on
            // the production PowerSync view, a real ADD COLUMN on the
            // NativeDatabase test path. Legacy rows keep action_id NULL — no
            // backfill (which Action was current when a historical stint ran is
            // unreconstructable), and totals are unaffected because every
            // time-spent derivation aggregates by task_id.
            await _addColumnIfTable(m, timeLogs, timeLogs.actionId);
          }
          if (from < 28) {
            // Drop the retired next-action cursor (issue #525, ADR-0024).
            // `actions` is the only next-action grain; nothing has read or
            // written this column since ADR-0022.
            //
            // A no-op on the production path — `todos` is a PowerSync view and
            // _dropColumnIfTable short-circuits on views, exactly like the v19
            // `waiting_for` drop. The view simply stops projecting the key on
            // the next cold start, when PowerSync regenerates it from
            // powersyncSchema; the orphaned key stays in the ps_data__todos
            // JSON blob, unreachable. On the NativeDatabase path (tests, fresh
            // local stores) this is a real ALTER TABLE ... DROP COLUMN.
            await _dropColumnIfTable('todos', 'next_action_text');
          }
        },
      );

  /// Maximum retained rows in `sync_dead_letters`; [recordSyncDeadLetter]
  /// prunes least-recently-occurred-first beyond this so the table cannot
  /// grow unbounded.
  // not configurable: bounded diagnostic buffer, not user-facing behaviour.
  static const int syncDeadLetterCap = 200;

  /// Record a non-retryable upload failure (see
  /// `JeevesBackendConnector.classifyUploadError`) and prune the rows with the
  /// stalest last occurrence (`createdAt`, id as tie-breaker) beyond
  /// [syncDeadLetterCap] — a failure that keeps repeating is refreshed by the
  /// upsert below and must outlive older one-off failures, so pruning cannot
  /// go by insertion order.
  ///
  /// Idempotent per failure: a repeat of the same (table, row, op, status) —
  /// e.g. a batch retried after a partial failure re-uploading an entry that
  /// was already dead-lettered — refreshes the existing row's payload, body,
  /// and timestamp instead of accumulating duplicates. Insert and prune run
  /// in one transaction so the cap holds at every observable point.
  Future<void> recordSyncDeadLetter({
    required String tableName,
    required String op,
    required String rowId,
    required String? opData,
    required int statusCode,
    required String? responseBody,
  }) async {
    await transaction(() async {
      await into(syncDeadLetters).insert(
        SyncDeadLettersCompanion.insert(
          targetTable: tableName,
          op: op,
          rowId: rowId,
          opData: Value(opData),
          statusCode: statusCode,
          responseBody: Value(responseBody),
        ),
        onConflict: DoUpdate(
          (old) => SyncDeadLettersCompanion(
            opData: Value(opData),
            responseBody: Value(responseBody),
            createdAt: Value(DateTime.now()),
          ),
          target: [
            syncDeadLetters.targetTable,
            syncDeadLetters.rowId,
            syncDeadLetters.op,
            syncDeadLetters.statusCode,
          ],
        ),
      );
      final keepNewest = selectOnly(syncDeadLetters)
        ..addColumns([syncDeadLetters.id])
        ..orderBy([
          OrderingTerm.desc(syncDeadLetters.createdAt),
          OrderingTerm.desc(syncDeadLetters.id),
        ])
        ..limit(syncDeadLetterCap);
      await (delete(syncDeadLetters)
            ..where((t) => t.id.isNotInQuery(keepNewest)))
          .go();
    });
  }

  /// Live count of recorded dead letters — folded into the sync status
  /// surface so a non-empty table shows as a sync error.
  Stream<int> watchSyncDeadLetterCount() {
    final count = countAll();
    final query = selectOnly(syncDeadLetters)..addColumns([count]);
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  /// Invalidates Drift stream queries reading the `todos` view (and, when
  /// [includeTodoTags] is set, the `todo_tags` view) after a direct write to
  /// that view, independent of the SQLite `changes()` row count of the write.
  ///
  /// In production `todos` / `tags` / `todo_tags` are PowerSync **views** with
  /// INSTEAD OF triggers (see [powersyncSchema]). A Drift `UpdateStatement.write`
  /// or `DeleteStatement.go` against a view reports `changes() == 0` — the
  /// trigger body, not the view, is what actually mutates rows — so Drift's
  /// built-in stream invalidation, which is gated on `rows > 0`, never fires.
  /// That leaves the async `SqliteAsyncDriftConnection` bridge
  /// (`PowerSyncDatabase.updates` → `handleTableUpdates`) as the *only* path
  /// that refreshes view-backed watchers. When that bridge is momentarily
  /// silent — observed on the first cold start of a new planning day, during
  /// the initial-sync window (#342) — the Inbox / Next Actions lists and their
  /// badges freeze until the app is restarted.
  ///
  /// Every `TodoDao` method that writes the `todos` view directly
  /// (via `update(todos)…write(…)` / `delete(todos)…go()`) must call this right
  /// after the write, giving Drift a second, in-process invalidation path so the
  /// live lists never depend solely on the bridge. It is a harmless idempotent
  /// re-run under `NativeDatabase` (tests), where the underlying write already
  /// reported `rows > 0` and notified. Methods built on `customUpdate` /
  /// `customInsert` (e.g. `markDone`, `setIntent`) notify
  /// unconditionally and need no extra call. Callers that also edit person tags
  /// pass [includeTodoTags] so the `todo_tags`-backed watchers refresh too.
  ///
  /// The emitted [TableUpdate]s carry no [UpdateKind]: a null kind matches every
  /// registered stream query regardless of insert/update/delete, so the same
  /// call correctly serves update callers (`applyRouting`) and delete callers
  /// (`deleteOutcome`) without the caller having to thread the kind
  /// through. Over-notifying a kind-filtered watcher would at worst cause a
  /// redundant re-query; under-notifying is the bug we are fixing.
  void notifyTodosViewWrite({bool includeTodoTags = false}) => notifyUpdates({
        const TableUpdate('todos'),
        if (includeTodoTags) const TableUpdate('todo_tags'),
      });

  /// The [notifyTodosViewWrite] analogue for the Capture views (issue #184).
  ///
  /// `captures` / `capture_outcomes` / `capture_tags` are PowerSync views with
  /// INSTEAD OF triggers in production, so a direct Drift write reports
  /// `changes() == 0` and Drift's stream invalidation never fires (ADR-0010).
  /// Every [CaptureDao] write calls this right after the write. All three
  /// table updates are emitted with a null [UpdateKind] so Inbox, provenance,
  /// and tag-hint watchers all refresh regardless of which view was touched;
  /// over-notifying at worst causes a redundant re-query.
  void notifyCapturesViewWrite() => notifyUpdates({
        const TableUpdate('captures'),
        const TableUpdate('capture_outcomes'),
        const TableUpdate('capture_tags'),
      });

  /// The [notifyTodosViewWrite] analogue for the `actions` view (issue #471).
  ///
  /// In production PowerSync exposes `actions` as a view with INSTEAD OF
  /// triggers, so a direct Drift write reports `changes() == 0` and Drift's
  /// stream invalidation never fires (ADR-0010). Story 1 has no DAO that writes
  /// `actions` yet (the v26 backfill runs during migration, before any watcher
  /// exists, so it needs no notify) — this is wired now so the first
  /// Action-writing DAO in story 2 has the self-notify path ready.
  void notifyActionsViewWrite() => notifyUpdates({
        const TableUpdate('actions'),
      });

  /// The [notifyTodosViewWrite] analogue for the `time_logs` view (issue #476).
  ///
  /// In production `time_logs` is a PowerSync view with INSTEAD OF triggers, so
  /// a direct Drift write reports `changes() == 0` and Drift's stream
  /// invalidation never fires (ADR-0010). The terminal-transition hook in
  /// [ActionDao] (close-on-Done / close-and-reopen-on-supersede) writes
  /// `time_logs` inside the Action transaction, so its callers fire this right
  /// after commit — gated on [ActionWriteEffect.logChanged], so an Action
  /// mutation that touched no log never over-notifies the active-log and
  /// time-spent watchers.
  void notifyTimeLogsViewWrite() => notifyUpdates({
        const TableUpdate('time_logs'),
      });

  /// Runs [Migrator.addColumn] only when [table] is a real SQLite table.
  ///
  /// On production `todos` / `tags` / `todo_tags` are PowerSync-managed views
  /// (see [powersyncSchema]); `ALTER TABLE <view> ADD COLUMN` raises
  /// `SqliteException(1): Cannot add a column to a view`.  PowerSync already
  /// mirrors every Drift-declared column on its view, so skipping the ALTER
  /// is functionally equivalent.  Under `NativeDatabase.memory()` in tests
  /// the target is a real table and the migration runs normally.
  Future<void> _addColumnIfTable(
      Migrator m, TableInfo<Table, dynamic> table, GeneratedColumn column) async {
    final rows = await customSelect(
      "SELECT type FROM sqlite_master WHERE name = ?",
      variables: [Variable<String>(table.actualTableName)],
    ).get();
    if (rows.isEmpty) return; // Unknown object; don't guess.
    if (rows.first.read<String>('type') != 'table') return;
    final cols =
        await customSelect('PRAGMA table_info(${table.actualTableName})').get();
    if (cols.any((r) => r.read<String>('name') == column.name)) return;
    await m.addColumn(table, column);
  }

  /// Drops [columnName] from [tableName] only when the target is a real SQLite
  /// table (not a PowerSync view). Checks column existence before dropping to
  /// make the operation idempotent.
  Future<void> _dropColumnIfTable(String tableName, String columnName) async {
    final rows = await customSelect(
      "SELECT type FROM sqlite_master WHERE name = ?",
      variables: [Variable<String>(tableName)],
    ).get();
    if (rows.isEmpty || rows.first.read<String>('type') != 'table') return;
    final cols = await customSelect('PRAGMA table_info($tableName)').get();
    if (!cols.any((r) => r.read<String>('name') == columnName)) return;
    await customStatement('ALTER TABLE $tableName DROP COLUMN $columnName');
  }
}
