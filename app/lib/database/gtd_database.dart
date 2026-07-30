/// Local-first GTD database backed by Drift.
///
/// Accepts any Drift [QueryExecutor] so the same class serves both production (a
/// `SqliteAsyncDriftConnection` over `jeeves_domain.sqlite`, wrapped in
/// `DatabaseConnection.delayed`) and tests (`NativeDatabase.memory()`).
///
/// **Drift owns the schema, and every table is a real table.** The store is a
/// file of its own, created by [MigrationStrategy.onCreate] — so there is no
/// migration ladder: the previous store was PowerSync-managed, its
/// application-visible names were views over `ps_data__*`, and it is deleted
/// rather than converted (see `domain_store_io.dart` and ADR-0035). A device
/// whose local op log holds reduced state has it projected into the fresh file at
/// first open; a device without one starts empty.
///
/// Schema changes from here are ordinary Drift migrations — [schemaVersion] goes
/// to 2 with an `onUpgrade` step. `ALTER TABLE ... ADD COLUMN` and `DROP COLUMN`
/// both work again, which they did not while the targets were views.
library;

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

  /// Runs [body] as one capture scope: everything the DAO describes through
  /// [opCapture] inside it is buffered, coalesced per entity, and emitted only
  /// once [body] has completed — so a rolled-back write is never signed and
  /// queued. Scopes nest; only the outermost emits.
  ///
  /// The scope is identified by the token [DomainOpCapture.beginScope] returns,
  /// not by stack position, so two overlapping un-awaited calls cannot close
  /// each other's scope.
  ///
  /// Every public DAO write method wraps its whole body (transaction, writes
  /// and post-commit view notifies) in this.
  Future<T> capturing<T>(Future<T> Function() body) async {
    final scope = opCapture.beginScope();
    T result;
    try {
      result = await body();
    } catch (_) {
      opCapture.rollbackScope(scope);
      rethrow;
    }
    await opCapture.commitScope(scope);
    return result;
  }

  /// Plain-class DAO for universal search (no code generation required).
  late final SearchDao searchDao = SearchDao(this);

  /// DAO for synced key-value user preferences.
  late final UserPreferencesDao userPreferencesDao = UserPreferencesDao(this);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());

  /// Invalidates Drift stream queries reading `todos` (and, when
  /// [includeTodoTags] is set, `todo_tags`) after a write, independent of what
  /// Drift itself would notify.
  ///
  /// **Still required now the store is Drift's own** (ADR-0010), for two reasons
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
  /// relies on it for rows reduced in from another device (ADR-0010). All three
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
  /// Fired by every [ActionDao] write and by the projector (ADR-0010).
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
