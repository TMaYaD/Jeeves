/// Drift table declarations for the domain read model.
///
/// Drift owns this schema outright — see `gtd_database.dart`. Which of these
/// tables the op-log spine carries is declared in `sync/collection_codecs.dart`,
/// the one registry that decides what travels on the wire; there is no marker on
/// the table classes, because a build-time marker and a runtime codec map are two
/// answers to one question.
library;

import 'package:drift/drift.dart';
import '../utils/uuid.dart';

// ---------------------------------------------------------------------------
// todos
// ---------------------------------------------------------------------------

/// One row per Outcome.
///
/// **There is no stored time-spent total here.** Time spent on an Outcome is
/// derived from `SUM(time_logs)` at read time — see
/// `TimeLogDao.totalMinutesSubquery`, which values an open stint at `now()`. The
/// surfaces that display it read that derivation directly; nothing caches it,
/// because a cached total is a value that can only ever be stale (ADR-0030).
class Todos extends Table {
  /// The longest title a row holds.
  static const int maxTitleLength = 500;

  TextColumn get id => text().clientDefault(() => uuid.v4())();

  /// The limit is a literal here on purpose, and it must stay equal to
  /// [maxTitleLength].
  ///
  /// Drift reads a length constraint out of the source with `readIntLiteral`,
  /// which takes an integer literal and nothing else. A constant reference is
  /// not a literal, so it reads as "no limit": the generated code drops the
  /// check and the store accepts a title of any length. Nothing says so — the
  /// column simply stops refusing. `outcome_title_limit_test.dart` holds the
  /// two numbers together.
  TextColumn get title => text().withLength(max: 500)();
  TextColumn get notes => text().nullable()();
  IntColumn get priority => integer().nullable()();
  DateTimeColumn get dueDate => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// ISO-8601 UTC timestamp; non-null when the task has been completed.
  TextColumn get doneAt => text().nullable()();

  /// Orthogonal intent: next | maybe | trash (migration 0015).
  TextColumn get intent => text()
      .clientDefault(() => 'next')
      .customConstraint(
        "NOT NULL DEFAULT 'next' CHECK (\"intent\" IN ('next','maybe','trash'))",
      )();

  /// Estimated effort in minutes (nullable).
  IntColumn get timeEstimate => integer().nullable()();

  /// Energy required: low | medium | high (nullable).
  TextColumn get energyLevel => text().nullable()();

  /// How this todo entered the inbox: manual | share_sheet | voice | ai_parse (nullable).
  TextColumn get captureSource => text().nullable()();

  TextColumn get locationId => text().nullable()();
  TextColumn get userId => text()();

  /// Timestamp of the last clarifying micro-act on this Outcome.
  ///
  /// Stamped by the DAO whenever the user performs an act of *thinking about
  /// the Outcome* per CONTEXT.md ("Clarification stamps last_clarified_at per
  /// micro-act"). Stamping writes include:
  ///   - Outcome creation (Capture → Outcome)
  ///   - title / notes / Intent / due-date edits
  ///   - any Action mutation (next-action text, energy, time-estimate, …)
  ///   - PersonBlocker (person-tag) add / remove
  ///   - Outcome completion or trashing (and the reverse: restore)
  ///
  /// Non-stamping writes include current-Action completion (engagement, not
  /// clarification), TimeLog writes, and Area / Label changes (organising).
  /// Drives the re-clarification ("Stale") predicate; see todo_dao.dart's
  /// _needsReviewWhere.
  DateTimeColumn get lastClarifiedAt => dateTime().nullable()();

  /// Retired: no code writes it and no predicate reads it. The column is kept
  /// so existing values keep round-tripping through sync and import.
  DateTimeColumn get lastNextActionCompletionAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// time_logs
// ---------------------------------------------------------------------------

/// One row per focus stint on a task.
///
/// Timestamps are ISO-8601 UTC text strings.
/// `ended_at` is null while the stint is still running.
class TimeLogs extends Table {
  /// Supplied by the writer — `TimeLogDao` mints it, so there is no
  /// `clientDefault` to disagree with the id the authored op carries.
  TextColumn get id => text()();
  TextColumn get userId => text()();
  TextColumn get taskId => text().references(Todos, #id)();

  /// The Action engaged when this stint ran (ADR-0001 story 6, issue #476).
  ///
  /// NULL means "no Action attribution available" — a pre-Action-era log, a
  /// defensive Actionless edge where the Outcome had no `current` Action at open
  /// time, or a log whose Action was later deleted (`ON DELETE SET NULL`, so a
  /// deleted Action detaches its logs rather than deleting them). The row still
  /// carries [taskId] (Outcome-grain) attribution, so every time-spent total
  /// (which aggregates by `task_id`) is unaffected either way.
  ///
  /// `onDelete: setNull` matches the backend FK (Alembic 0029): a nullable FK
  /// whose parent-delete rule is SET NULL, never CASCADE (which would destroy
  /// time data) or RESTRICT (which would block the delete).
  TextColumn get actionId =>
      text().nullable().references(Actions, #id, onDelete: KeyAction.setNull)();

  /// ISO-8601 UTC string: when the stint started.
  TextColumn get startedAt => text()();

  /// ISO-8601 UTC string: when the stint ended; null while still running.
  TextColumn get endedAt => text().nullable()();

  /// UUID of the focus session this log row belongs to; null for pre-FocusSession rows.
  TextColumn get focusSessionId =>
      text().nullable().references(FocusSessions, #id)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// sprints
// ---------------------------------------------------------------------------

/// One row per recorded Sprint (issue #910): a timebox spent on an Action.
///
/// Timestamps are canonical ISO-8601 UTC text with exactly three fractional
/// digits (`2026-07-28T05:12:03.042Z`), so the stored row equals what peers
/// receive. `ended_at` is null while the Sprint runs; when two devices end one
/// Sprint at different instants the earlier end stands (`min_timestamp_value`).
/// A Break is the gap between Sprints and is not recorded.
class Sprints extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text()();

  /// The Action the Sprint ran on. NULL once that Action was deleted
  /// (`ON DELETE SET NULL`, like `time_logs.action_id`): its Sprints detach,
  /// they are never deleted.
  TextColumn get actionId =>
      text().nullable().references(Actions, #id, onDelete: KeyAction.setNull)();

  TextColumn get startedAt => text()();
  TextColumn get endedAt => text().nullable()();

  /// The Sprint length that was set when it started, so a restart or a second
  /// device can show the countdown without device-only storage.
  IntColumn get plannedDurationMinutes => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// focus_sessions
// ---------------------------------------------------------------------------

/// One row per planning session. An open session (ended_at IS NULL) is the
/// single source of truth for "what tasks are on today's plan" and
/// "which task is currently focused."
class FocusSessions extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();
  TextColumn get startedAt => text()();
  TextColumn get endedAt => text().nullable()();

  /// The task currently being focused on; null when no task is active.
  TextColumn get currentTaskId =>
      text().nullable().references(Todos, #id)();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// focus_session_tasks
// ---------------------------------------------------------------------------

/// Junction table: which todos are part of a focus session, in what order.
class FocusSessionTasks extends Table {
  /// Sync row identifier — not the domain key, which is (focus_session_id,
  /// task_id). The projector realigns it onto
  /// `focusSessionTaskIdFor(sessionId, taskId)` so every device converges on one
  /// row identity regardless of which authored the create (ADR-0025).
  TextColumn get id => text().unique().clientDefault(() => uuid.v4())();
  TextColumn get focusSessionId => text().references(FocusSessions, #id)();
  TextColumn get taskId => text().references(Todos, #id)();
  IntColumn get position => integer()();

  /// Per-task disposition chosen during session review, for **Plan members**.
  /// Off-Plan engaged Outcomes have no row here (the Plan never grows automatically —
  /// ADR-0002); their Dispositions live in [FocusSessionDispositions] instead.
  /// NULL = not yet reviewed (active session) or done task.
  /// 'rollover' = carry forward to next session's pre-selected list.
  /// 'leave' = return to Next (no mutation on todos).
  /// 'maybe' = defer; FocusSessionReviewNotifier writes intent='maybe' to todos.
  TextColumn get disposition => text().nullable()();

  /// The start time the user set for this Plan entry on the day timeline
  /// ("Set by you"; `pinned` in code). NULL = Jeeves places it. A property of
  /// the (session, Outcome) entry that dies with the session (ADR-0013); length
  /// is never stored — it is the estimate. Merges last-write-wins per field, and
  /// clearing it ("Let Jeeves move it") writes NULL.
  DateTimeColumn get pinnedStartAt => dateTime().nullable()();

  /// Denormalized from `focus_sessions.user_id` so a junction row carries its
  /// owner without a JOIN.
  TextColumn get userId => text()();

  /// The moment the user deliberately added this Outcome to the Plan during
  /// Execution (issue #700). NULL = chosen during Planning, i.e. the morning
  /// commitment. A Plan reader needs no filter for it: the Plan stays exactly
  /// the set of rows here; this only marks which of them joined late.
  DateTimeColumn get addedDuringExecutionAt =>
      dateTime().named('added_during_execution_at').nullable()();

  /// Groups the Plan entries of one accepted small-task suggestion (issue #407):
  /// entries sharing a value run back to back. NULL = not in a batch. Like
  /// [pinnedStartAt] it dies with the session, merges last-write-wins per field,
  /// and is cleared when the user moves a member.
  TextColumn get batchId => text().named('batch_id').nullable()();

  /// When the user answered "Not today" to a small-task suggestion that
  /// included this entry (issue #407). NULL = never declined. Dies with the
  /// session; the entry is not offered in a suggestion again.
  DateTimeColumn get batchSuggestionDeclinedAt =>
      dateTime().named('batch_suggestion_declined_at').nullable()();

  @override
  Set<Column<Object>> get primaryKey => {focusSessionId, taskId};
}

// ---------------------------------------------------------------------------
// focus_session_dispositions
// ---------------------------------------------------------------------------

/// Durable home for Review-phase Dispositions on **off-Plan engaged** Outcomes.
///
/// Dispositions partition by membership class:
///   - A Plan member's Disposition lives on [FocusSessionTasks.disposition]
///     (it already has a junction row from Planning).
///   - An off-Plan engaged Outcome has **no** `focus_session_tasks` row — the
///     Plan never grows automatically from engagement
///     (ADR-0002) — so its Disposition is recorded here, keyed by the
///     (FocusSession, Outcome) pair per CONTEXT.md § Engagement (Disposition is
///     a property of that relationship, independent of Plan membership).
///
/// Query helpers UNION the two homes so callers see one logical Disposition set
/// (`FocusSessionDao.getLastClosedSessionRolloverTaskIds`, the review-surface
/// stamp). Keeping this separate from `focus_session_tasks` preserves the
/// load-bearing invariant "the Plan *is* the set of `focus_session_tasks`
/// rows" — no Plan reader has to remember to filter a discriminator column.
class FocusSessionDispositions extends Table {
  /// Sync row identifier — not the domain key. Required (no random
  /// client default): callers must derive it deterministically via
  /// `focusSessionDispositionIdFor(sessionId, taskId)` (see focus_session_dao.dart)
  /// so re-recording the same pair collapses under INSERT OR REPLACE onto one
  /// stable sync identity instead of accumulating duplicate rows.
  TextColumn get id => text().unique()();
  TextColumn get focusSessionId => text().references(FocusSessions, #id)();
  TextColumn get taskId => text().references(Todos, #id)();

  /// Per-(FocusSession, Outcome) disposition: 'rollover' | 'leave' | 'maybe'.
  /// Same vocabulary as [FocusSessionTasks.disposition]. NULL is unused here —
  /// a row exists only once the user has dispositioned the off-Plan Outcome.
  TextColumn get disposition => text().nullable()();

  /// Denormalized from `focus_sessions.user_id` so a disposition row carries its
  /// owner without a JOIN.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {focusSessionId, taskId};
}

// ---------------------------------------------------------------------------
// Bypassed signals (CONTEXT.md § Engagement, Bypassed)
// ---------------------------------------------------------------------------

/// A FocusSession's Daily Planning passed an Outcome over **without putting it
/// on the Plan**: the user tapped Skip on it. Written by
/// `FocusSessionDao.openSession`, in the same scope as the Plan, so an abandoned
/// Planning performance records nothing. One row per (FocusSession, Outcome).
@DataClassName('FocusSessionPlanningBypass')
class FocusSessionPlanningBypasses extends Table {
  /// Sync row identifier, derived from the pair
  /// (`focusSessionPlanningBypassIdFor`).
  TextColumn get id => text().unique()();
  TextColumn get focusSessionId => text().references(FocusSessions, #id)();
  TextColumn get taskId => text().references(Todos, #id)();

  DateTimeColumn get recordedAt => dateTime()();
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {focusSessionId, taskId};
}

/// An Outcome's existing due date was moved **later** while the Outcome was on
/// the Plan of the open FocusSession. One row per (FocusSession, Outcome):
/// repeated edits collapse onto it and refresh `recorded_at`.
@DataClassName('FocusSessionReschedule')
class FocusSessionReschedules extends Table {
  /// Sync row identifier, derived from the pair
  /// (`focusSessionRescheduleIdFor`).
  TextColumn get id => text().unique()();
  TextColumn get focusSessionId => text().references(FocusSessions, #id)();
  TextColumn get taskId => text().references(Todos, #id)();
  DateTimeColumn get recordedAt => dateTime()();
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {focusSessionId, taskId};
}

/// The decision log of the Weekly Review's Bypassed step: one row per Outcome the user moved to
/// Someday/Maybe or Trashed from it. An event log, so the id is random. The
/// latest row for an Outcome is part of its Bypassed floor.
@DataClassName('OutcomeBypassDecision')
class OutcomeBypassDecisions extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get taskId => text().references(Todos, #id)();

  /// `maybe` | `trash`.
  TextColumn get decision => text()();
  DateTimeColumn get decidedAt => dateTime()();
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// tags
// ---------------------------------------------------------------------------

/// The `tags.type` value that backs a Label.
///
/// **`'context'` is the stored value, and it stays `'context'`.** The value
/// predates the name "Label" — these are the `@` rows the app used to show as
/// "Tags" — and it is what every released build already reads as its Label
/// surface. Folding the retired `'label'` value into this one therefore costs
/// only the few rows the sync cutover minted, and no wire change
/// (docs/SYNC.md).
const String labelTagType = 'context';

/// The retired `tags.type` value: what the sync cutover minted Labels as,
/// before they were folded into [labelTagType].
///
/// A row still carrying it is retyped on arrival, so no build after this one
/// writes it.
const String retiredLabelTagType = 'label';

/// Every `tags.type` value that names a Label: the current one and the retired
/// one.
///
/// A reader that looks for a Label has to accept both, because a peer on an
/// older build can still send the retired value.
const Set<String> labelTagTypes = {labelTagType, retiredLabelTagType};

class Tags extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get name => text().withLength(max: 100)();
  TextColumn get color => text().nullable()();

  /// GTD discriminator: context | project | area | person
  ///
  /// **`'context'` backs Label**, and it is the only value that does: the
  /// retired `'label'` value is retyped to it on arrival
  /// (`TagDao.retypeRetiredLabelTags`), never stored by a current build.
  TextColumn get type => text()
      .withDefault(const Constant('context'))
      .clientDefault(() => 'context')();

  TextColumn get userId => text()();

  /// The op-log identity. Client-random UUIDv4 by protocol policy
  /// (`sync/ids.dart`) — a Tag id is *not* derived from `(name, type)`.
  @override
  Set<Column<Object>> get primaryKey => {id};

  /// **No `(name, type)` uniqueness constraint, deliberately** (ADR-0043).
  ///
  /// `(name, type)` is the *user-facing* identity of a Tag, but not its op-log
  /// one, and it is an **eventual** invariant rather than a schema one: two
  /// devices each creating "Alice"/`person` offline fork into two entities by
  /// design, and reduced state can hold both. This table is a projection of
  /// reduced state, so it has to be able to represent what reduced state holds —
  /// a constraint here made `DomainProjector`'s id-addressed insert raise
  /// `SqliteException(2067)` and roll back the whole pull batch (#605).
  ///
  /// The invariant is enforced instead by [TagDao.findOrCreateTag] locally, and
  /// converged across devices by `DomainReconciler`, whose fold pass collapses
  /// each duplicate group onto `MIN(id)` by authoring real ops. Note the contrast
  /// with [UserPreferences], whose `UNIQUE (user_id, key)` stays: its entity id
  /// *is* derived from `(workspace, key)`, so two devices writing one preference
  /// are two writes to one entity and can never fork.
}

// ---------------------------------------------------------------------------
// user_preferences
// ---------------------------------------------------------------------------

/// Cross-device synced key-value preference store.
///
/// One row per (user_id, key) pair. `value` is JSON-encoded; NULL is a
/// tombstone. `updated_at` drives LWW arbitration when local and server rows
/// conflict at sign-in (see MigrationService).
class UserPreferences extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();
  TextColumn get key => text()();
  TextColumn get value => text().nullable()();
  TextColumn get updatedAt => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
        {userId, key}
      ];
}

// ---------------------------------------------------------------------------
// todo_tags  (junction)
// ---------------------------------------------------------------------------

class TodoTags extends Table {
  /// A sync row identifier, carried even though the *logical* identity of a
  /// junction row is (todo_id, tag_id): the op log names an entity by one id, so
  /// the pair has to reduce to a single derived one.  Callers should derive it
  /// deterministically via `todoTagIdFor(todoId, tagId)` (see tag_dao.dart)
  /// so re-assigning the same tag collapses under INSERT OR REPLACE instead
  /// of accumulating duplicate rows.
  TextColumn get id => text().unique()();

  TextColumn get todoId => text().references(Todos, #id)();
  TextColumn get tagId => text().references(Tags, #id)();

  /// Denormalized from `todos.user_id` so a junction row carries its owner
  /// without a JOIN.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {todoId, tagId};
}

// ---------------------------------------------------------------------------
// captures
// ---------------------------------------------------------------------------

/// A raw, unprocessed fragment the user put into the system because it has
/// their attention (ADR-0006). Distinct from an Outcome (`todos`): a Capture
/// is pending clarification and is many-to-many with Outcome via
/// [CaptureOutcomes].
///
/// Inbox membership is `clarified_at IS NULL`. Clarifying a Capture stamps
/// `clarified_at` exactly once — whether it produced new Outcomes, merged into
/// existing ones, or was discarded (a zero-Outcome clarification is a
/// legitimate verdict). A stamped Capture is never deleted; it persists as
/// provenance for the Outcomes it clarified into. `last_clarified_at` on the
/// Outcome is a distinct concept (staleness of the *current* clarification)
/// and lives on `todos`, not here.
class Captures extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get title => text().withLength(max: 500)();
  TextColumn get notes => text().nullable()();

  /// How this Capture entered the system:
  /// manual | share_sheet | voice | ai_parse | nirvana_import (nullable).
  TextColumn get captureSource => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// NULL = still in the Inbox. Stamped once when the clarify act completes.
  DateTimeColumn get clarifiedAt => dateTime().nullable()();

  DateTimeColumn get updatedAt => dateTime().nullable()();
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// capture_outcomes  (provenance join: which Outcomes a Capture clarified into)
// ---------------------------------------------------------------------------

/// Device-local record that a one-time data conversion has run on this
/// store (issue #238: time-named context tags). **No sync codec, no op**: a
/// marker replicated from another device would claim a conversion this device
/// never ran. Written in the same transaction as the conversion it names.
class LocalMigrationMarkers extends Table {
  TextColumn get name => text()();
  DateTimeColumn get completedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {name};
}

/// The outbox between a domain write and the sync host: one clocked [Change]
/// per entity per committed transaction, written in the **same transaction** as
/// the domain rows it describes. The host drains it into merge state and deletes
/// a row only after the sync store has committed it, so a process killed anywhere
/// in between replays the row rather than losing the change.
///
/// **Device-local: no sync codec, no op.** It is a queue, not data — consuming a
/// row is not data loss, because the change is in merge state first. `change_id`
/// is minted once at capture and rides into the change sequence, which is what
/// makes a replay after a crash between the two stores' commits a no-op.
class PendingChanges extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get changeId => text().unique()();
  TextColumn get changeJson => text()();
}

/// The one row naming this device to the clock: the random node id that breaks
/// HLC ties when the device has no member id, and whether the op-log member id
/// has taken over.
///
/// Lives in the domain store so a local write can be clocked without waiting on,
/// or failing with, the sync store. **Device-local: never replicated** — a copied
/// node id would make two devices indistinguishable to the tie-break.
class DeviceClockIdentity extends Table {
  /// Always 1: the table is a single row.
  IntColumn get id => integer().withDefault(const Constant(1))();

  /// 32 lowercase hex characters (16 random bytes).
  TextColumn get deviceNodeId => text()();

  /// The op-log member id while the device is enrolled, else null. Persisted so a
  /// write on the first turn of an enrolled cold start is stamped with it.
  TextColumn get enrolledMemberIdHex => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A file attached to a Capture — today, an image shared in through the
/// Android share sheet. The bytes live in app-private storage at
/// `relative_path` (relative to the application support directory).
///
/// **Device-local: no sync codec, no op.** The image bytes never replicate, so a
/// replicated row would dangle on every peer. A domain store rebuilt from the op
/// log therefore loses these links (the files stay on disk).
class CaptureAttachments extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get captureId =>
      text().references(Captures, #id, onDelete: KeyAction.cascade)();
  TextColumn get relativePath => text()();
  TextColumn get mimeType => text()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Many-to-many provenance link between a [Captures] row and an Outcome
/// (`todos`). The join *is* the provenance — "this Outcome was captured from
/// these N Captures" — there is no separate audit table (ADR-0006). Merge
/// links, never consumes: a Capture keeps its rows here after it is stamped.
class CaptureOutcomes extends Table {
  /// Sync row identifier — not the domain key. Derive it
  /// deterministically via `captureOutcomeIdFor(captureId, outcomeId)`
  /// (see capture_dao.dart) so a repeat link is a stable no-op under INSERT OR
  /// IGNORE (preserving the original `created_at`) instead of accumulating
  /// duplicate rows.
  TextColumn get id => text().unique()();
  TextColumn get captureId =>
      text().references(Captures, #id, onDelete: KeyAction.cascade)();
  TextColumn get outcomeId =>
      text().references(Todos, #id, onDelete: KeyAction.cascade)();

  /// When the link was made — the clarifying micro-act that carved (or merged
  /// into) this Outcome.
  DateTimeColumn get createdAt => dateTime()();

  /// Denormalized from the parent's `user_id` so a junction row carries its
  /// owner without a JOIN.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {captureId, outcomeId};
}

// ---------------------------------------------------------------------------
// capture_tags  (tag hints carried from capture time)
// ---------------------------------------------------------------------------

/// Tag *hints* a Capture carried from capture time. Distinct from Organising:
/// tag hints never stamp anything and are not List membership — they surface
/// only as removable chips on the Outcome draft at clarify time and as prefill
/// when merging into an existing Outcome (issue #184). Mirrors `todo_tags`
/// conventions.
class CaptureTags extends Table {
  /// Sync row identifier — derive it deterministically via
  /// `captureTagIdFor(captureId, tagId)` (see capture_dao.dart).
  TextColumn get id => text().unique()();
  TextColumn get captureId =>
      text().references(Captures, #id, onDelete: KeyAction.cascade)();
  TextColumn get tagId =>
      text().references(Tags, #id, onDelete: KeyAction.cascade)();

  /// Denormalized from the parent's `user_id` for the per-user bucket.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {captureId, tagId};
}

// ---------------------------------------------------------------------------
// actions
// ---------------------------------------------------------------------------

/// A first-class Action against an Outcome (`todos`) — ADR-0001, story 1
/// (issue #471). An owned entity (client-declared `id`, like [Captures]),
/// distinct from the Outcome it belongs to, carrying one of four roles over
/// its lifetime: `planned` / `current` / `done` / `superseded`.
///
/// A superseded Action carries **no** linkage metadata — no
/// `superseded_by_id`, no dedicated `superseded_at`; a superseded row's
/// timestamp is read from `updated_at`, and the Outcome's history is the
/// time-ordered chain of terminated Action rows.
///
/// `actions` is the only next-action grain. The server-side backfill (Alembic
/// 0028) gave one `current` Action to each Outcome that held a non-blank
/// cursor **at the moment that migration ran** — it is a one-time pass, not
/// ongoing reconciliation, so an Outcome with a blank cursor got none and
/// renders Actionless until re-clarified. It mints a deterministic uuid5 id
/// from the Outcome id (see `backfillActionIdFor`, ADR-0019) so no version
/// skew can duplicate a row. The `todos.next_action_text` cursor it read from
/// no longer exists.
///
/// The `(outcome_id, role)` index is declared rather than left to the query
/// planner: the "has a current Action" `EXISTS` predicate behind the Next List
/// and the re-clarification queue (ADR-0001 story 3) runs once per candidate
/// Outcome on every re-emission, and without the index that is a full scan of
/// `actions` per candidate. It used to be installed by the storage engine on the
/// engine's own backing table; a Drift-owned store has to declare it.
@TableIndex(name: 'idx_actions_outcome_role', columns: {#outcomeId, #role})
class Actions extends Table {
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get outcomeId =>
      text().references(Todos, #id, onDelete: KeyAction.cascade)();
  TextColumn get userId => text()();

  /// The Action text. Named `text` to match the backend column, but the getter
  /// is `actionText` because a getter literally named `text` would clash with
  /// Drift's `text()` column builder.
  TextColumn get actionText => text().named('text')();

  /// `planned` | `current` | `done` | `superseded`. The CHECK lives here (the
  /// Drift column), mirroring [Todos.intent]; the backend has no Postgres CHECK.
  TextColumn get role => text().customConstraint(
        "NOT NULL CHECK (\"role\" IN ('planned','current','done','superseded'))",
      )();

  /// Planned-queue order; NULL for non-planned roles.
  IntColumn get position => integer().nullable()();

  /// Per-action metadata: low | medium | high (nullable).
  TextColumn get energyLevel => text().nullable()();

  /// Estimated effort in minutes (nullable).
  IntColumn get timeEstimate => integer().nullable()();

  /// TimeContext (issue #238): canonical JSON, see `models/time_context.dart`.
  /// NULL = not gated. Belongs to this Action row; never copied to a successor.
  TextColumn get timeContext => text().named('time_context').nullable()();

  /// Timeboxed (issue #923): whether the estimate is a limit rather than a
  /// guess. NULL and false both mean off. Belongs to this Action row; never
  /// copied to a successor.
  BoolColumn get timeboxed => boolean().nullable()();

  /// The Place this Action is at (issue #239): a `places.id`.
  ///
  /// NULL = no place. **No SQL foreign key**: the log has none, and a
  /// reference to a place that no longer exists must be representable — it
  /// reads as "no place" rather than hiding the Action.
  ///
  /// One column carries both kinds of place, a named one and a one-time pin,
  /// so last-write-wins on a single field keeps "at most one place per Action"
  /// true even when two devices disagree.
  TextColumn get placeId => text().named('place_id').nullable()();

  /// The time window this Action is gated by (issue #239): a
  /// `time_windows.id`.
  ///
  /// NULL = no window. Like [placeId], no SQL foreign key, and like
  /// `time_context` it belongs to this Action row and is never copied to a
  /// successor. A named window and a Time context are exclusive: setting one
  /// clears the other.
  TextColumn get timeWindowId => text().named('time_window_id').nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// Client-stamped; a superseded row's timestamp is read from here.
  DateTimeColumn get updatedAt => dateTime().nullable()();

  /// Completion timestamp; non-null once the Action is `done`.
  DateTimeColumn get doneAt => dateTime().nullable()();

  /// The instant the Action was **stopped at its Timeboxed limit** (issue #49).
  ///
  /// NULL on every Action that was not stopped at a limit. Set together with
  /// `role='superseded'`: the Action was neither completed nor replaced — the
  /// approach ran out of time and the user said so.
  ///
  /// The mark says *how* the Action ended; it says nothing about what came
  /// after, so it is not linkage metadata.
  DateTimeColumn get stoppedAtLimitAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// places  (issue #239)
// ---------------------------------------------------------------------------

/// One row per named place **or** one-time pin.
///
/// A place is a point plus an area: the point is the centre, the radius is
/// how far the area reaches. **Both kinds live in this table**, distinguished
/// by [kind]: a `named` place is listed for the user to choose, a `pin` is a
/// one-off the user dropped on the map and belongs to the one Action that
/// points at it.
///
/// The point is stored in microdegrees (degrees × 1 000 000) rather than as a
/// float, because the wire format carries no float (ADR-0026): an integer
/// rounds the same way on every device.
class Places extends Table {
  /// The longest name a row holds.
  static const int maxNameLength = 100;

  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();

  /// `named` | `pin`.
  ///
  /// A pin is not listed anywhere: it belongs to the one Action that points
  /// at it, and it goes when that reference moves away.
  TextColumn get kind => text()();

  /// The name the user gave the place. Required for a `named` place, optional
  /// for a pin, which may carry a short name of its own.
  ///
  /// At most [maxNameLength] characters. The column carries no length
  /// constraint of its own — it is nullable, and a nullable column's length is
  /// enforced where the row is written, not by the store.
  TextColumn get name => text().nullable()();

  /// Degrees × 1 000 000, rounded (−90 000 000 … 90 000 000).
  IntColumn get latitudeMicrodegrees => integer()();

  /// Degrees × 1 000 000, rounded (−180 000 000 … 180 000 000).
  IntColumn get longitudeMicrodegrees => integer()();

  /// How far the area reaches, in metres. 50 … 2000; a new place takes 150.
  IntColumn get radiusMeters => integer()();

  DateTimeColumn get createdAt => dateTime()();

  /// Null while the place has never been edited.
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// time_windows  (issue #239)
// ---------------------------------------------------------------------------

/// One row per named time window.
///
/// A window is a set of hours, one entry per day of the week, with days that
/// have no hours simply absent. The hours are stored as canonical JSON — the
/// same fixed-key-order spelling `TimeContext` uses — so two devices that
/// build the same hours write the same bytes.
///
/// A window may run past midnight and belongs to the day it starts: Monday
/// 22:00–02:00 is open Monday 22:00 through Tuesday 02:00.
class TimeWindows extends Table {
  /// The longest name a row holds.
  static const int maxNameLength = 100;

  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();

  /// The name the user gave the window.
  ///
  /// The limit is a literal here on purpose, and it must stay equal to
  /// [maxNameLength] — see [Todos.title] for why the two are kept apart.
  TextColumn get name => text().withLength(max: 100)();

  /// The hours, as canonical JSON (see `models/time_window_hours.dart`).
  TextColumn get hours => text()();

  DateTimeColumn get createdAt => dateTime()();

  /// Null while the window has never been edited.
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// ---------------------------------------------------------------------------
// habits  (the Habit data model — issue #401)
// ---------------------------------------------------------------------------

// The five tables below hold the Habit data model.
//
// **Two kinds of timestamp, and they are not interchangeable.** An *instant* is
// canonical ISO-8601 UTC text with exactly three fractional digits
// (`2026-11-18T05:12:03.042Z`) — `encodeInstant`, the form `sprints` already
// stores. A *day* is a local calendar date, `YYYY-MM-DD`. A day is the local
// calendar day (ADR-0049): there is no timezone column anywhere, because the
// day a Check-in counts for is the day the user meant, not an instant
// converted into one.
//
// **No CHECK constraints.** The DAO validates what it writes and the reads
// tolerate what they meet, so a row a future build writes is not refused by
// an older one.

/// One row per Habit: something the user does regularly, on a rule they chose.
///
/// A Habit has **no state column**. Active, paused and archived are derived
/// from [HabitInactivePeriods]: a day is archived when an archived period
/// covers it, paused when a paused period covers it, active otherwise. The
/// derivation lives in the DAO, so the stored rows can never disagree with it.
///
/// **Device-local until Habits sync**: this table has no codec and authors no
/// op, like `capture_attachments`. A store rebuilt from the op log does not
/// bring the Habits back, and they are not in the data export.
class Habits extends Table {
  /// Client-random UUIDv4, minted by the writer.
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();

  /// The Habit's name, as the user wrote it.
  TextColumn get title => text().withLength(max: 500)();

  /// Free text; null when the user wrote none.
  TextColumn get notes => text().nullable()();

  /// The effort the Habit asks for: low | medium | high (nullable).
  ///
  /// The three values an Action carries, so the Outcome editors the Habit
  /// form reuses work on them unchanged.
  TextColumn get energyLevel => text().nullable()();

  /// How long the Habit takes, in minutes (nullable).
  IntColumn get timeEstimateMinutes => integer().nullable()();

  /// What anchors the Habit in the day: none | part_of_day | clock_time |
  /// after_habit | before_habit.
  ///
  /// **The anchor is not dated.** It says where the Habit sits in the day, not
  /// how much of it is expected, so it is not a commitment and no copy of it
  /// is kept per period — only the target and the repeat rule are judged per
  /// period, and those live in [HabitCommitments].
  TextColumn get anchorKind => text().withDefault(const Constant('none'))();

  /// morning | afternoon | evening — set when [anchorKind] is `part_of_day`.
  TextColumn get anchorPartOfDay => text().nullable()();

  /// Local `HH:MM`, 24-hour — set when [anchorKind] is `clock_time`.
  TextColumn get anchorClockTime => text().nullable()();

  /// The Habit this one follows or precedes — set when [anchorKind] is
  /// `after_habit` or `before_habit`.
  ///
  /// NULL once that Habit is gone. An archived target is refused at write
  /// time rather than stored, and a chain that would loop is refused too.
  TextColumn get anchorHabitId => text().nullable().references(Habits, #id)();

  /// The Place this Habit is at (issue #1075): a `places.id`.
  ///
  /// NULL = no place. **No SQL foreign key**, like [Actions.placeId]: the
  /// log has none, and a reference to a Place that no longer exists must be
  /// representable — it reads as "no place" rather than hiding the Habit.
  ///
  /// One column carries both kinds of Place, a named one and a one-time pin,
  /// so last-write-wins on a single field keeps "at most one place per Habit"
  /// true even when two devices disagree.
  TextColumn get placeId => text().named('place_id').nullable()();

  /// When the Habit was created (an instant).
  TextColumn get createdAt => text()();

  /// When the Habit was last edited (an instant); null while it never has been.
  TextColumn get updatedAt => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One row per commitment: the repeat rule and the measurable target a period
/// of a Habit is judged by.
///
/// **Append-only.** A row is never updated and never deleted. A change of rule
/// or target is a new row, and the row in force on a day is the most recently
/// created one whose effective start is on or before that day — so a finished
/// period keeps the commitment it was judged by, without anything having to
/// be rewritten.
///
/// This is a code name, not a glossary term: the design calls it "the
/// commitment a period is judged by".
///
/// The stored row is `HabitCommitmentRow`, not `HabitCommitment`: the domain
/// value of that name (`models/habit_commitment.dart`) is what the app
/// reasons about, and the row is only its stored form.
@DataClassName('HabitCommitmentRow')
class HabitCommitments extends Table {
  /// Client-random UUIDv4, minted by the writer.
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();

  /// The Habit this commitment governs.
  TextColumn get habitId => text().references(Habits, #id)();

  /// The day the user made this commitment (a day).
  ///
  /// The rule's effective start is derived from it — the day itself for the
  /// daily kinds, the Monday of its week for a weekly target, the first of
  /// its month for a monthly one — so only the chosen day is stored and the
  /// week start stays a code constant.
  TextColumn get chosenOn => text()();

  /// When the row was written (an instant). The tie-break between two
  /// commitments chosen on the same day.
  TextColumn get createdAt => text()();

  /// every_day | chosen_weekdays | times_per_week | times_per_month |
  /// every_n_days.
  TextColumn get repeatKind => text()();

  /// The chosen weekdays as canonical JSON, ISO 1 = Monday … 7 = Sunday.
  /// Null unless [repeatKind] is `chosen_weekdays`.
  TextColumn get chosenWeekdays => text().nullable()();

  /// N — how many times a week or a month. Null unless [repeatKind] is
  /// `times_per_week` or `times_per_month`.
  IntColumn get timesPerPeriod => integer().nullable()();

  /// The N of `every_n_days`. Null unless [repeatKind] is `every_n_days`.
  IntColumn get intervalDays => integer().nullable()();

  /// A hint, not a rule: canonical JSON of the days the user prefers —
  /// weekdays 1–7 for a week, dates 1–31 for a month. Stored as given; a
  /// 31st stays a 31st.
  TextColumn get preferredDays => text().nullable()();

  /// The unit the target is counted in ("pages", "glasses"). Null for a
  /// binary Habit.
  TextColumn get unitLabel => text().nullable()();

  /// How much of one period the target asks for. Set together with
  /// [unitLabel] for a measurable Habit, null for both on a binary one.
  RealColumn get dailyTargetAmount => real().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One row per Check-in: the user saying they did the Habit on a day.
///
/// A day can hold several Check-ins — two glasses of water are two Check-ins,
/// not one row with a count of two, because each is its own record with its
/// own time.
///
/// **A Check-in does not store a copy of the target.** What the day's
/// Check-ins are read against is the commitment in force that day, so the
/// target cannot disagree with itself when the target changes mid-day.
@TableIndex(
  name: 'idx_habit_check_ins_habit_day',
  columns: {#habitId, #countsForDay},
)
class HabitCheckIns extends Table {
  /// Client-random UUIDv4, minted by the writer.
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();

  /// The Habit this Check-in is for.
  TextColumn get habitId => text().references(Habits, #id)();

  /// The day this Check-in counts for (a day).
  ///
  /// The caller passes it, so a Check-in made in the evening for the day being
  /// closed counts for that day and not for today.
  TextColumn get countsForDay => text()();

  /// When the Check-in was made (an instant).
  TextColumn get checkedInAt => text()();

  /// How much was done, for a measurable Habit. Null on a binary one.
  RealColumn get measuredAmount => real().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One row per pause or archive period of a Habit.
///
/// The dates are stored rather than a flag, so that "was this Habit paused
/// on Tuesday?" is a fact about a row and not a question about the Habit's
/// current state.
class HabitInactivePeriods extends Table {
  /// Client-random UUIDv4, minted by the writer.
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();

  /// The Habit the period belongs to.
  TextColumn get habitId => text().references(Habits, #id)();

  /// paused | archived.
  TextColumn get kind => text()();

  /// The first day the period covers (a day).
  TextColumn get startsOn => text()();

  /// The first day the Habit is active again (a day); null while the period
  /// is open.
  ///
  /// A pause with an end date stores it, so the pause ends with no timer.
  /// Resuming by hand sets it to today; archiving closes an open pause.
  TextColumn get endsBefore => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// The Habit's Area and Labels.
///
/// Mirrors `todo_tags`: the logical identity of a junction row is the pair,
/// and the row carries a derived id so a repeat assignment collapses into
/// one row instead of accumulating duplicates.
///
/// A Habit holds at most one Area — an `area` tag — and any number of
/// Labels. The DAO keeps that rule; the schema does not, because a
/// constraint here would refuse a row rather than correct it.
class HabitTags extends Table {
  /// A derived row identifier — `habitTagIdFor(habitId, tagId)`, so the same
  /// pair always lands on the same row.
  TextColumn get id => text().unique()();

  /// The Habit that carries the tag.
  TextColumn get habitId => text().references(Habits, #id)();

  /// The tag: an Area (`area`) or a Label.
  TextColumn get tagId => text().references(Tags, #id)();

  /// Denormalized from `habits.user_id` so a junction row carries its owner
  /// without a JOIN.
  TextColumn get userId => text()();

  @override
  Set<Column<Object>> get primaryKey => {habitId, tagId};
}

// ---------------------------------------------------------------------------
// habit_time_logs / habit_sprints  (time spent on a Habit in Focus Mode — #405)
// ---------------------------------------------------------------------------

/// One row per Focus Mode run on a Habit, breaks included — what a TimeLog is
/// for an Outcome, kept apart from it because a Habit is not an Outcome and
/// does not join the plan.
///
/// **Device-local until Habits sync**: no codec, no op, not in the data export,
/// the same as the Habit tables.
///
/// Instants are canonical ISO-8601 UTC text (`encodeInstant`). `ended_at` is
/// null while the Focus runs.
@TableIndex(name: 'idx_habit_time_logs_habit', columns: {#habitId})
class HabitTimeLogs extends Table {
  /// Client-random UUIDv4, minted by the writer.
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();

  /// The Habit the time was spent on.
  TextColumn get habitId => text().references(Habits, #id)();

  /// When the Focus started (an instant).
  TextColumn get startedAt => text()();

  /// When the Focus ended (an instant); null while it runs.
  TextColumn get endedAt => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One row per Sprint run on a Habit: what a Sprint is for an Action. A break
/// is the gap between two of them, as in [Sprints].
///
/// **Device-local until Habits sync**, like [HabitTimeLogs].
class HabitSprints extends Table {
  /// Client-random UUIDv4, minted by the writer.
  TextColumn get id => text().clientDefault(() => uuid.v4())();
  TextColumn get userId => text()();

  /// The Habit the Sprint ran on.
  TextColumn get habitId => text().references(Habits, #id)();

  /// When the Sprint started (an instant).
  TextColumn get startedAt => text()();

  /// When the Sprint ended (an instant); null while it runs.
  TextColumn get endedAt => text().nullable()();

  /// The Sprint length that was set when it started, in minutes.
  IntColumn get plannedDurationMinutes => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
