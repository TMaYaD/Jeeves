/// Local-first GTD database backed by Drift.
///
/// Accepts any Drift [QueryExecutor] so the same class serves both production (a
/// `SqliteAsyncDriftConnection` over `jeeves_domain.sqlite`, wrapped in
/// `DatabaseConnection.delayed`) and tests (`NativeDatabase.memory()`).
///
/// **Drift owns the schema, and every table is a real table.** The store is a
/// file of its own, created by [MigrationStrategy.onCreate] — the previous store
/// was PowerSync-managed, its application-visible names were views over
/// `ps_data__*`, and it is deleted rather than converted (see
/// `domain_store_io.dart`). A device whose local op log holds
/// reduced state has it projected into the fresh file at first open; a device
/// without one starts empty.
///
/// Schema changes are ordinary Drift migrations from there: bump [schemaVersion]
/// and add a step to `onUpgrade`. Structural `ALTER TABLE` works again, which it
/// did not while the targets were views. `schema_baseline_test.dart` pins both
/// the shape `onCreate` builds and each `onUpgrade` step's effect.
library;

import 'dart:async';

import 'package:drift/drift.dart';
import '../utils/uuid.dart';

import 'daos/action_dao.dart';
import 'daos/capture_dao.dart';
import 'daos/focus_session_dao.dart';
import 'daos/search_dao.dart';
import 'daos/tag_dao.dart';
import 'daos/time_log_dao.dart';
import 'daos/todo_dao.dart';
import 'daos/user_preferences_dao.dart';
import '../sync/domain_op_capture.dart';
import 'tables.dart';

export 'tables.dart';

part 'gtd_database.g.dart';

@DriftDatabase(
  tables: [Todos, Tags, TodoTags, TimeLogs, FocusSessions, FocusSessionTasks, FocusSessionDispositions, UserPreferences, Captures, CaptureOutcomes, CaptureTags, Actions],
  daos: [TagDao, TodoDao, TimeLogDao, FocusSessionDao, CaptureDao, ActionDao],
)
class GtdDatabase extends _$GtdDatabase {
  GtdDatabase(super.executor, {this.opCapture = const NoopDomainOpCapture()});

  /// The op-log capture seam every DAO write path describes its effect
  /// through. Defaults to the no-op, which is what an un-enrolled device stays
  /// on for ever — it authors nothing. `sync_lifecycle.dart` binds it on
  /// activation.
  final DomainOpCapture opCapture;

  /// The transactional write primitive: a capturing scope **is** one
  /// transaction. Runs [body] inside [transaction] and inside a capture scope,
  /// so scope lifetime and transaction lifetime are the same object's lifetime.
  /// Everything the DAO describes through [opCapture] inside it is buffered,
  /// coalesced per entity, and emitted only once the transaction has
  /// committed — a rolled-back write is never signed and queued, and a
  /// committed write can never lose its op (the two failure directions #598
  /// closed).
  ///
  /// Scopes nest; only the outermost emits, and the inner [transaction] a
  /// nested `capturing` opens is a savepoint that merges into the outer commit
  /// (drift ≥ 2.0 nested transactions). The scope is identified by the token
  /// [DomainOpCapture.beginScope] returns, not by stack position, so two
  /// overlapping un-awaited calls cannot close each other's scope.
  ///
  /// **The scope rides the zone the body runs in** — every effect described
  /// anywhere inside [body], at any nesting depth and across every `await`, is
  /// filed into *this* scope, and a nested `capturing` is this scope's child
  ///. That is not a nicety: this method opens its scope as its first
  /// synchronous statement while [body] waits behind drift's `ensureOpen`, so two
  /// un-awaited calls always both open before either body runs, and "the scope
  /// begun most recently" would attribute the first caller's writes to the
  /// second — signing a rolled-back write, or discarding a committed one's op
  /// when the second rolls back. [DomainOpCapture.beginScope] is called before
  /// the zone is entered, so the parent it records is the *enclosing* scope
  /// rather than an overlapping stranger.
  ///
  /// Every domain write — a single DAO method or a multi-DAO service
  /// composition — runs its whole body (transaction, writes and post-commit
  /// view notifies) through this. Composing writes with a bare [transaction]
  /// instead is refused; see the [transaction] override.
  Future<T> capturing<T>(Future<T> Function() body) async {
    final scope = opCapture.beginScope();
    T result;
    try {
      result = await opCapture.runInScope(
        scope,
        () => _capturedTransaction(body),
      );
    } catch (_) {
      opCapture.rollbackScope(scope);
      rethrow;
    }
    await opCapture.commitScope(scope);
    return result;
  }

  /// A transaction for writes that must **never** author ops — the one
  /// deliberate un-captured write path. Its sole production caller is
  /// [DomainProjector], which materialises reduced state that is already on the
  /// op log: re-authoring it would be a feedback loop. Runs [action] inside a
  /// real [transaction] but marks the capturing zone, so nested DAO writes it
  /// makes (the projector's own `customStatement`s never describe effects, but
  /// the marker keeps the [transaction] guard satisfied) do not trip the guard.
  ///
  /// It also **masks** any enclosing capture scope, so "authors nothing" is
  /// enforced rather than incidental: nested inside a [capturing] body, a
  /// described effect throws instead of being filed into that body's scope.
  Future<T> uncapturedTransaction<T>(Future<T> Function() action) =>
      opCapture.runInScope(null, () => _capturedTransaction(action));

  /// Runs [action] inside a real drift [transaction], having first marked the
  /// current zone as a capturing zone so the [transaction] override lets the
  /// nested call through. Shared by [capturing] and [uncapturedTransaction] —
  /// the two, and only two, legitimate ways to open a domain-store transaction.
  Future<T> _capturedTransaction<T>(Future<T> Function() action) => runZoned(
        () => super.transaction(action),
        zoneValues: {_capturingZoneKey: true},
      );

  /// Runs a schema-migration [body] with the [transaction] guard held open,
  /// but — unlike [_capturedTransaction] — WITHOUT opening a transaction of its
  /// own. Drift's `Migrator` recreate steps (e.g. `alterTable`) open their own
  /// `transaction` on this db object, which hits the [transaction] override,
  /// *and* toggle `PRAGMA foreign_keys` immediately outside that transaction —
  /// a sequence sqlite only honours when nothing has already wrapped the
  /// migration in an outer transaction (the pragma is silently a no-op inside
  /// one). So this marks the zone and nothing more: the migrator keeps
  /// ownership of the transaction boundary, and the marker keeps the guard
  /// satisfied while it does. Migrations are the same op-free category as
  /// [uncapturedTransaction] — they run during `onCreate`/`onUpgrade`, before
  /// any DAO write path is live, so nothing describes an effect and nothing is
  /// ever signed or queued. The capture scope is masked for the same reason
  /// [uncapturedTransaction] masks it — nothing a migration does may be filed
  /// into a scope.
  Future<T> _duringMigration<T>(Future<T> Function() body) =>
      opCapture.runInScope(
        null,
        () => runZoned(body, zoneValues: {_capturingZoneKey: true}),
      );

  /// Marks a zone opened by [capturing] / [uncapturedTransaction] / a schema
  /// migration ([_duringMigration]). Present ⇒ a [transaction] call is inside a
  /// sanctioned scope; absent ⇒ refuse.
  static final Object _capturingZoneKey = Object();

  /// Refuses a bare domain-store [transaction] opened outside a capturing zone.
  ///
  /// Post-flip a bare `transaction` composing capturing DAO writes emits each
  /// DAO's ops the moment that DAO returns — while the outer transaction is
  /// still open — so a later rollback leaves the op log asserting a write the
  /// store never kept. Refusing loudly beats corrupting quietly: domain writes
  /// go through [capturing]; writes that must author nothing go through
  /// [uncapturedTransaction].
  ///
  /// **The guard's reach is the db object, honestly.** This override intercepts
  /// only `GtdDatabase.transaction` — calls made on the database object. A DAO
  /// is a `DatabaseAccessor`, so a DAO-internal bare `transaction(...)`
  /// dispatches through `DatabaseConnectionUser.transaction` and bypasses this
  /// override entirely. The invariant "the broken shape cannot be composed
  /// silently" therefore holds at the db-object level — which is where the
  /// service/import compositions that #598 fixed live — and, after the collapse
  /// that leaves no DAO spelling `transaction` at all, in practice everywhere;
  /// but the enforcement itself reaches only db-object callers.
  @override
  Future<T> transaction<T>(Future<T> Function() action,
      {bool requireNew = false}) {
    if (Zone.current[_capturingZoneKey] != true) {
      throw StateError(
        'Domain writes go through GtdDatabase.capturing, which is the '
        'transaction boundary; a bare GtdDatabase.transaction is refused so a '
        'rolled-back write can never leave a signed op behind. For writes that '
        'must never author ops, use GtdDatabase.uncapturedTransaction.',
      );
    }
    return super.transaction(action, requireNew: requireNew);
  }

  /// Plain-class DAO for universal search (no code generation required).
  late final SearchDao searchDao = SearchDao(this);

  /// DAO for synced key-value user preferences.
  late final UserPreferencesDao userPreferencesDao = UserPreferencesDao(this);

  @override
  int get schemaVersion => 3;

  /// Completes with the [OpeningDetails] of this store's one open.
  ///
  /// **The migration runs on the first query, not at construction.** Production
  /// wraps the executor in `DatabaseConnection.delayed` (`database_provider.dart`),
  /// so anything read off this object immediately after building it reports the
  /// pre-migration state. A caller that has to act on "did this launch upgrade the
  /// schema?" therefore issues a query to force the open and awaits this.
  ///
  /// Fed from [MigrationStrategy.beforeOpen], which drift runs on **every** open,
  /// so the future always completes. Feeding it from `onUpgrade` instead would
  /// leave it unresolved for ever on a launch that migrates nothing, and hang the
  /// caller.
  Future<OpeningDetails> get opened => _opened.future;

  final Completer<OpeningDetails> _opened = Completer<OpeningDetails>();

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          if (!_opened.isCompleted) _opened.complete(details);
        },
        // Every migration entry point runs inside [_duringMigration]: drift's
        // recreate steps open a `transaction` on this db object, which the
        // [transaction] guard would otherwise refuse (a migration is outside
        // any [capturing] scope). Migrations author no ops, so the marker lets
        // them through without weakening the guard's runtime teeth.
        onCreate: (m) => _duringMigration(m.createAll),
        onUpgrade: (m, from, to) => _duringMigration(() async {
          // v2 (issue #604): drop `todos.time_spent_minutes`, a denormalised
          // time-spent cache with no write path — time spent is derived from
          // `SUM(time_logs)` at read time. The column carried nothing on a v1
          // store: every row held the declared `0`, so this loses no data.
          //
          // A recreate rather than `ALTER TABLE ... DROP COLUMN`: that statement
          // needs sqlite 3.35, and the bundled library's version is a property
          // of whatever `sqlite3_flutter_libs` build a device ended up with.
          // `alterTable` copies the surviving columns into a table built from
          // the current declaration, re-creates the indices, and cycles
          // `PRAGMA foreign_keys` itself, so `time_logs.task_id` survives the
          // swap.
          if (from < 2) {
            await m.alterTable(TableMigration(todos));
          }
          // v3 (issue #605): drop `UNIQUE (name, type)` from `tags`. Tag ids are
          // client-random, so two devices each creating "Alice"/`person` offline
          // reduce to two entities — and this table is a projection of reduced
          // state, which therefore has to be able to hold two rows. The constraint
          // made [DomainProjector]'s id-addressed insert raise instead, rolling
          // back every entity in the pull batch. `(name, type)` is now an eventual
          // invariant `DomainReconciler` folds towards (ADR-0043).
          //
          // A recreate for the same reason as v2 — the constraint is a table
          // constraint, so there is no `ALTER TABLE` that removes it. `alterTable`
          // copies every column into a table built from the current declaration,
          // re-creates the explicit indices, and skips the `sqlite_autoindex` the
          // dropped constraint owned; it runs inside drift's own transaction, so an
          // interruption rolls the whole swap back. No row and no column is lost —
          // including the `capture_tags` rows already orphaned by `merge` (#645),
          // which survive as the dangling references they were.
          if (from < 3) {
            await m.alterTable(TableMigration(tags));
          }
        }),
      );

  /// Invalidates Drift stream queries reading `todos` (and, when
  /// [includeTodoTags] is set, `todo_tags`) after a write, independent of what
  /// Drift itself would notify.
  ///
  /// **Still required now the store is Drift's own**, for two reasons
  /// that outlive the PowerSync views this was written for:
  ///
  /// 1. **The projector.** Reduced state is written into these tables by
  ///    `DomainProjector` through `customStatement`, which carries no `updates:`
  ///    set — so an entity reduced in from another device refreshes nothing
  ///    unless something fires this. That is the whole reason a *projected* row
  ///    appears in a live list at all.
  /// 2. **Cross-table reads.** Two GTD list watchers name only
  ///    `{todoTags, tags}` in `readsFrom`, and several Action-grain writes touch
  ///    `actions` without touching `todos` at all — Drift will not invalidate a
  ///    `todos` watcher for either, but the surfaces do change.
  ///
  /// Every `TodoDao` method that writes `todos` directly calls this right after
  /// the write. Methods built on `customUpdate` / `customInsert` with an explicit
  /// `updates:` set (e.g. `markDone`, `setIntent`) notify already and need no
  /// extra call; a redundant call is harmless. Callers that also edit person tags
  /// pass [includeTodoTags] so the `todo_tags`-backed watchers refresh too.
  ///
  /// The emitted [TableUpdate]s carry no [UpdateKind]: a null kind matches every
  /// registered stream query regardless of insert/update/delete, so the same
  /// call correctly serves update callers (`applyRouting`) and delete callers
  /// (`deleteOutcome`) without the caller having to thread the kind
  /// through. Over-notifying a kind-filtered watcher would at worst cause a
  /// redundant re-query; under-notifying is the bug this exists to prevent.
  void notifyTodosViewWrite({bool includeTodoTags = false}) => notifyUpdates({
        const TableUpdate('todos'),
        if (includeTodoTags) const TableUpdate('todo_tags'),
      });

  /// The [notifyTodosViewWrite] analogue for the Capture tables (issue #184).
  ///
  /// Every [CaptureDao] write calls this right after the write, and the projector
  /// relies on it for rows reduced in from another device. All three
  /// table updates are emitted with a null [UpdateKind] so Inbox, provenance and
  /// tag-hint watchers all refresh regardless of which table was touched;
  /// over-notifying at worst causes a redundant re-query.
  void notifyCapturesViewWrite() => notifyUpdates({
        const TableUpdate('captures'),
        const TableUpdate('capture_outcomes'),
        const TableUpdate('capture_tags'),
      });

  /// The [notifyTodosViewWrite] analogue for `actions` (issue #471).
  ///
  /// Fired by every [ActionDao] write and by the projector.
  void notifyActionsViewWrite() => notifyUpdates({
        const TableUpdate('actions'),
      });

  /// The [notifyTodosViewWrite] analogue for `time_logs` (issue #476).
  ///
  /// The terminal-transition hook in [ActionDao] (close-on-Done /
  /// close-and-reopen-on-supersede) writes `time_logs` inside the Action
  /// transaction, so its callers fire this right after commit — gated on
  /// [ActionWriteEffect.logChanged], so an Action mutation that touched no log
  /// never over-notifies the active-log and time-spent watchers.
  void notifyTimeLogsViewWrite() => notifyUpdates({
        const TableUpdate('time_logs'),
      });

  /// The [notifyTodosViewWrite] analogue for `tags`.
  ///
  /// [TagDao] reaches `tags` through `INSERT OR REPLACE`, which Drift notifies on
  /// its own — the explicit notify is what makes a *projected* Tag (one reduced
  /// in from another device, #550) refresh the tag pickers and cloud.
  void notifyTagsViewWrite() => notifyUpdates({
        const TableUpdate('tags'),
      });

  /// The [notifyTodosViewWrite] analogue for the FocusSession tables.
  ///
  /// Every Plan / Focus / Review surface reads across `focus_sessions`,
  /// `focus_session_tasks` and `focus_session_dispositions`, so they notify as one
  /// group — the same shape [notifyCapturesViewWrite] uses.
  void notifyFocusSessionsViewWrite() => notifyUpdates({
        const TableUpdate('focus_sessions'),
        const TableUpdate('focus_session_tasks'),
        const TableUpdate('focus_session_dispositions'),
      });

  /// The [notifyTodosViewWrite] analogue for `user_preferences`.
  ///
  /// [UserPreferencesDao] writes through `customUpdate` / `customInsert` with
  /// an explicit `updates:` set, which notifies unconditionally; the projector
  /// writes the same table without one, so it fires this instead.
  void notifyUserPreferencesViewWrite() => notifyUpdates({
        const TableUpdate('user_preferences'),
      });
}
