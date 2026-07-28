# Architecture

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

This document describes the architectural design of Jeeves, a productivity-focused todos application.

## High-Level System Overview

The system follows an offline-first architecture, allowing clients to work securely and seamlessly without an internet connection, while continuously syncing with the central database when online.

- **Frontend Clients:** Flutter-based applications supporting mobile (iOS/Android), web, and desktop.
- **Backend Service:** A Python-based FastAPI service responsible for business logic, integrations, and AI endpoints.
- **Sync Engine:** PowerSync for real-time, bidirectional replication between local embedded databases and the central PostgreSQL database.
- **Primary Database:** PostgreSQL.

### Mono-repo Structure

```text
jeeves/
├── app/          # Flutter application codebase
├── backend/      # FastAPI Python service
├── infra/        # Docker Compose and local developer environment
├── spec/         # Language-neutral protocol fixtures shared by both suites
└── docs/         # Architecture, requirements, and design docs
```

## Architectural Principles

- **Flat, Explicit Code**: We prefer flat folder structures and explicit code flows over deep abstractions.
- **Group by Feature**: Code is organized by feature modules (e.g., Auth, Todos, Settings) rather than technical layers (Controllers, Models, Views).
- **Minimal Coupling**: Dependencies between features should be minimized to allow them to be developed, tested, and maintained independently.
- **RESTful APIs**: We prefer RESTful resources over generic actions (Ex: `POST /session` over `/login`, `POST /user` over `/register`).

## Tech Stack Details

### Frontend (Flutter)

Located in `app/`.

- **State Management:** `flutter_riverpod` and `riverpod_annotation`.
- **Local Storage:** Offline-first architecture using `drift` and `sqlite3_flutter_libs` as the structured SQL engine.
- **API Communication:** `dio` and `retrofit`.
- **Data Models:** `freezed` and `json_serializable` for robust immutable models.
- **Sync:** PowerSync (`powersync ^2.x` Dart package) — bidirectional sync via `JeevesBackendConnector` and a self-hosted `journeyapps/powersync-service` instance.
- **Web storage:** OPFS-backed SQLite via `WebPowerSyncOpenFactory` from `package:powersync/web.dart`, using the WASM worker assets in `app/web/`.

### Backend (Python/FastAPI)

Located in `backend/`.

- **Framework:** `fastapi` with Python 3.12+ running on `uvicorn`.
- **Database ORM:** `sqlalchemy` (with `asyncpg` for async I/O) and `alembic` for migrations.
- **Validation:** `pydantic`.
- **Background Tasks:** `celery` with `redis`.
- **AI Integrations:** `anthropic` client library.
- **Architecture:** Follows the [12-Factor App methodology](./BACKEND_GUIDELINES.md) (stateless processes, environment-based configuration, etc.).

### Sync Engine

PowerSync provides bidirectional offline-first sync between the Flutter SQLite store and PostgreSQL:

- The Flutter app connects to a self-hosted `journeyapps/powersync-service` instance.
- Twelve sync shapes are replicated per user: `todos`, `tags`, `todo_tags`, `time_logs`, `focus_sessions`, `focus_session_tasks`, `focus_session_dispositions` (issue #418, ADR-0016), `user_preferences`, the Capture split (issue #184, ADR-0006) `captures`, `capture_outcomes`, `capture_tags`, and `actions` (issue #471, ADR-0001 story 1) — every bucket filters on `user_id` directly, since PowerSync rejects JOINs in bucket data queries as a fatal sync-rules error. The junction tables (`todo_tags`, `focus_session_tasks`, `focus_session_dispositions`, `capture_outcomes`, `capture_tags`) carry a denormalized `user_id` for this purpose (Alembic 0008, 0025, 0027, 0026); `actions` is an owned entity (client-declared `id`, like `captures`) that denormalizes `user_id` from its Outcome for the same reason (Alembic 0028). `focus_session_dispositions` is the durable home for Review Dispositions on off-Plan engaged Outcomes — Plan-member Dispositions stay on `focus_session_tasks.disposition`, keeping the Plan fixed (ADR-0002); see `docs/SYNC.md § The focus-session upload contract`. `captures` splits Capture from Outcome at the storage layer (Inbox = `captures.clarified_at IS NULL`); Alembic 0026 non-destructively moves the old `todos.clarified = false` rows across, and `carveOutLocalInbox` does the same move on-device for users who have never signed in. The Inbox and every clarify surface now read and write these tables — see `docs/SYNC.md § The Capture-split upload contract`. `actions` replicates and, from issue #472 (ADR-0001 story 2), is written on every next-action write path via `ActionDao`; from issue #473 (story 3) it is also what the app *reads* for current-Action existence and text. Story 9 (issue #479, ADR-0022) completed the move by making `actions` the only grain, and #525 (ADR-0024) dropped the `todos.next_action_text` cursor outright — it is no longer declared, projected or replicated on the client. See the `actions` data-model note below and `docs/SYNC.md § The actions upload contract`.
- The backend issues short-lived JWTs from `GET /powersync/credentials`; PowerSync validates them using the shared `SECRET_KEY`.
- Local writes made through the PowerSync client are queued and uploaded to the backend REST API via `JeevesBackendConnector.uploadData()`.
- PowerSync uses Postgres for internal bucket storage — no additional database is required.
- Sync rules deploy with the backend. `infra/powersync/sync-config.yaml` is the only place bucket definitions exist; Backend CD pushes to Dokku (whose release phase runs Alembic) and then runs `infra/dokku/publish-sync-config.sh`, which publishes that file to the PowerSync app as `POWERSYNC_CONFIG_B64` and no-ops when it is unchanged. A migration and the buckets that read its tables therefore ship in one pipeline run rather than one shipping and the other waiting on a human. The ordering is sequential, not atomic — see ADR-0017 and `infra/dokku/README.md` for the residual window and the manual two-phase procedure destructive migrations still need.
- Conflict resolution: last-write-wins by default, with a per-key strategy registry for `user_preferences` (snooze floors use a non-regressing `maxTimestampValue` rule; list/set keys are provisioned for merge). See [SYNC.md](./SYNC.md) for the full conflict matrix, the tombstone invariant, and the PowerSync write-checkpoint behaviour.

#### The `actions` table (issue #471 story 1, issue #472 story 2, issue #473 story 3, issue #474 story 4, issue #478 story 8, ADR-0001)

`actions` is the first-class Action entity that replaced the `todos.next_action_text` cursor. It is an owned entity keyed by a client-declared `id` (like `captures`), belonging to one Outcome via `outcome_id` (FK → `todos.id`, `ON DELETE CASCADE`), with a denormalized `user_id` for the per-user bucket. Columns: `text`, `role` (`planned` / `current` / `done` / `superseded`; the CHECK lives on the Drift column, not Postgres, mirroring `todos.intent`), `position` (planned-queue order, NULL otherwise), `energy_level`, `time_estimate`, `created_at`, `updated_at`, `done_at`. Per **ADR-0018** there is no `superseded_at` and no `superseded_by_id` — a superseded row's termination time is read from `updated_at`, and the Outcome's history is the time-ordered chain of terminated rows.

**Story 2 made the table live for writes; story 3 (issue #473) moved the reads onto it.** `ActionDao` (`app/lib/database/daos/action_dao.dart`) is the single in-app writer and owns the lifecycle primitives — `setCurrentAction` (create-or-in-place-edit; identical text is a no-op; never auto-supersedes), `editAction` (in-place field edit by id, role-agnostic, used by story 7 for metadata), `supersedeCurrentAction` (the explicit-affordance role flip — no linkage columns per ADR-0018; exercised by tests only this story, since the Abandon / re-clarify affordances that call it are stories 5/8), and `clearCurrentAction` (supersede with no replacement, the Action side of a blank cursor). The stamping rule is encoded once, in `ActionDao._stampOutcome`: every public primitive stamps `last_clarified_at` (an Action mutation is a clarifying micro-act — CONTEXT.md § Clarification); no-ops, the multi-current convergence repair, the reconciliation sweep, and — the one deliberate exception — `completeCurrentAction` do not. The 0..1-current invariant is app-enforced (no partial unique index — a unique violation would `500` → infinite retry), so any primitive that finds more than one `current` row first converges deterministically: keep the winner by greatest `COALESCE(updated_at, created_at)`, tie-break smallest `id`, retire the rest. Every write self-notifies (`notifyActionsViewWrite`, ADR-0010) after commit.

**The cursor is gone (story 9, issue #479, ADR-0022; dropped by #525, ADR-0024).** `actions` is the only grain: `todos.next_action_text` is no longer declared in `tables.dart`, no longer generated into the PowerSync schema, and no longer projected by `TodoDao.todoProjectionSql`. A Drift `from < 28` migration drops it from any real table; on the production PowerSync view the drop is a no-op and the view simply stops projecting the key at the next cold start. `powersync_schema_consistency_test.dart` asserts it stays gone. The one-field surfaces survive as thin entry points that drive `ActionDao` and nothing else — `TodoDao.setCurrentActionText` (blank routes to `clearCurrentAction`), `TodoDao.setCurrentActionTextIfActionless` (issue #501 — the **atomic actionless-mirror**: reads the `current` Action and writes the Action inside **one** transaction, so a `current` Action landed by sync cannot slip between the check and the write; it takes `setCurrentActionText`'s write path verbatim through the shared `_applySetCurrentActionText` body when Actionless, and is a pure no-op — no write, no stamp, no notify — when a `current` Action already exists; blank text is a caller error), `TodoDao.applyRouting`'s `nextAction` / `waitingFor` arms (blank → clear, absent → no-op; the other arms write no Action), and `TodoDao.deleteOutcome` (carve-undo cascades the Outcome's Action rows explicitly — the local view enforces no FK cascade). Their atomicity and notify semantics are unchanged; only the storage moved, and the two text surfaces were renamed off the cursor's name onto the Action's (`setNextActionText` → `setCurrentActionText`) so no Dart identifier outlives the column.

There is consequently **no correspondence between cursor and Action to maintain**, and the old *blank cursor ⟺ no `current` row* invariant is gone. Nothing should restore it — an Outcome-column mirror of the current Action's text, re-added under any name, re-arms every path ADR-0022 deleted. Each role transition used to clear or rewrite the cursor to keep the startup sweep from undoing it; none does now, and none needs to, because the sweep reads no Outcome column at all. (Reasoning from "the row each transition leaves behind" would be unsound: `removePlannedAction` is a hard delete and leaves none — see the Reconciliation sweep below.) `_applySetCurrentActionText` still writes `todos`, but only the `last_clarified_at` / `updated_at` stamp: these surfaces stamp even when the Action write is a no-op, because re-submitting the identical phrase is still a clarifying micro-act.

Two consequences are deliberate and load-bearing. **The `todos` view-notify stays** everywhere it fired before, including where the `todos` write is now gone (`applyCompleteCurrentAction` writes nothing to `todos` at all): two list watchers name only `{todoTags, tags}` in `readsFrom`, and the async bridge is briefly silent on cold start, so removing a notify as "redundant" is an unforced ADR-0010 regression that widget tests will not catch. **`todos.updated_at` no longer churns** on Action completion, so "the Outcome row changed" is no longer a signal a completion emits.

A peer that predates the Actions table has no Action grain to write, and the cursor it would write instead no longer exists to be read. Nothing repairs such a row at runtime, deliberately: the sweep never adopts and never retires a lone `current` Action. Read the Action row, always. ADR-0022 records why losing such a client's edit is preferred to letting it clobber Action-grain history, and why downgrading across this change is hazardous; ADR-0024 records why the rollout condition is "no device on a build predating #479" rather than "no device on a pre-drop build".

**Metadata is Action-grain (story 7, issue #477).** `energy_level` and `time_estimate` now describe the *action of doing*, so a replacement Action never inherits the effort metadata of the one it replaced. Four rules govern the coexistence of the Action rows and the still-present Outcome columns. Unlike `next_action_text` these columns are **not** retired and were **not** dropped with it: D2 reads them, so the mirror is load-bearing rather than compatibility scaffolding, and it deliberately outlives the cursor. Retiring it needs a D2 read-rule redesign of its own.

- **D1 — mirror invariant.** `ActionDao.applyEditAction` upholds it by construction: after writing the `actions` row it checks the role it loaded, and on a `current` row mirrors the *post-write* effort values onto `todos.energy_level` / `time_estimate` in the same transaction (a `clear*` flag nulls a column on both sides). No caller has to know a row's role to keep the two sides in step — which matters because a `planned` row can turn `current` under a caller that captured it earlier (a promote synced from another device, or one the UI has not re-emitted), and role-agnostic writes would otherwise land effort on the Action while the columns kept the old values. `TodoDao.updateFields` — the one live writer of these fields on an existing Outcome — writes the columns and then drives `applyEditAction` inside one transaction with the same timestamp; the two writes agree, so the mirror is idempotent rather than duplicated.
- **D2 — read rule (per-field COALESCE).** Every effort read resolves to `COALESCE(current Action's value, Outcome column)`. `TodoDao.effectiveEnergyLevelSql` / `effectiveTimeEstimateSql` express it (over `ActionDao.currentActionColumnSubquery`, the metadata analogue of `TimeLogDao.totalMinutesSubquery`), and `TodoDao.todoProjectionSql` — the single Todo projection every Todo-producing query in `TodoDao`, `FocusSessionDao` and `SearchDao` now selects — aliases the effective expressions back to `energy_level` / `time_estimate`, so `Todo.map(row)` hydrates the model with Action-grain values and **no UI or provider changed**. On a legacy store (no `actions` rows) every COALESCE falls through to the Outcome column, so totals are identical before and after the cutover.
- **D3 — metadata while Actionless.** Values set on an Actionless Outcome stay on the Outcome columns as draft; when its first `current` Action is born, `ActionDao.applySetCurrentAction` seeds the birth Action from those columns when the caller passes none — landing the draft on the Action for every creation path (clarify `applyRouting`, `setCurrentActionText`, `setCurrentActionTextIfActionless`) with no signature change.
- **D4 — supersession does not inherit, and must mirror.** `ActionDao.applySupersedeCurrentAction` takes the replacement's metadata and, when it mints a replacement, writes that (possibly NULL) metadata onto the Outcome columns **in the same transaction**; `_promoteRow` does the same for the promoted row. The justification is the D2 read rule alone — it is a *per-field* COALESCE over the Outcome columns, so leaving the retired Action's estimates behind would let them resurface against its replacement, or on the Outcome once it goes Actionless. That is exactly the stale inheritance the story forbids. This is not cursor bookkeeping and did not go away with the cursor: the sweep never writes metadata onto an existing Action, so no sweep-stability argument supports or requires it. The superseded row keeps its own frozen values (history is truthful).

**A `planned` Action's metadata is Action-local and is never mirrored.** The planned-queue effort pickers (`_PlanActionSheet`, issue #477) drive `ActionDao.addPlannedAction` / `editAction`, neither of which writes a `todos` **effort** column for a `planned` row. (Both do write `todos.last_clarified_at` and `updated_at` through `_stampOutcome` — every Action mutation is a clarifying micro-act.) The effort silence is required, not an omission: D2's COALESCE reads the Outcome columns as *the current Action's* values, so a planned row reaching them would be read back as the effort of an Action the user has not started — and a `planned` row is not even engageable (ADR-0004). The mirror is established at exactly the moment the row becomes current, by `_promoteRow` — shared by `applyPromotePlannedAction` and, on the "Replace current action" path, by `applySupersedeAndPromote`. (`applySupersedeCurrentAction` is the text-taking variant behind Abandon / `clearCurrentAction` / re-clarify-to-new; it mints a fresh Action and never sees a planned row.) So the feature needs no new bookkeeping to preserve D1–D4, and pointing `editAction` at a `current` row is safe rather than forbidden: `applyEditAction` mirrors on its own when the role it loaded is `current` (D1). The UI still routes only planned rows to it and `TodoDao.updateFields` is still the current-grain editor, but that is a division of labour now, not a load-bearing invariant — a role that flips between a sheet opening and its Save can no longer leave stale values behind to resurface when the Action is abandoned.

**`ActionDraft` is the boundary type, and no DAO takes it.** `app/lib/models/action_draft.dart` names an Action's editable attributes (`text`, `energyLevel`, `timeEstimateMinutes`) as one value, so a clarify surface or the plan sheet passes "the Action" rather than three loose parallel fields — and so "is there an Action here at all?" is answered by the draft being null. It reaches `ClarificationService` and `TaskDetailNotifier` and stops: both unpack it into the existing scalar DAO parameters. Keeping it out of `ActionDao` / `TodoDao` is deliberate — the D1–D4 machinery is unchanged by its existence and cannot regress because of it. One asymmetry the unpacking must preserve: `ClarificationService` writes the effort values via `insertOutcome` **before** calling `applyRouting`, because the birth Action seeds from those columns (D3); reversed, it would seed from empty ones. `TaskDetailNotifier.editAction` maps a null on the draft onto `ActionDao.editAction`'s `clear*` flag, since the DAO reads a bare null as "no change" — the sheet's semantics are replace, not patch.

**Reads (story 3, issue #473):** every question of the form "does this Outcome have a current Action, and what is it?" is answered from `actions`. `ActionDao` owns the read primitives — `getCurrentAction`, `watchCurrentAction`, and the batched `getCurrentActionTexts` the one-at-a-time review snapshots consume — and they are pure SELECTs: no transaction, no `last_clarified_at` stamp, no convergence, no view-notify (repair belongs to the writers and the startup sweep). Where a multi-current race is visible a read applies the same winner rule the writers use — greatest `COALESCE(updated_at, created_at)`, tie-break smallest `id` — so every surface and every device displays the same row without writing one. `TodoDao`'s list predicates use `EXISTS (SELECT 1 FROM actions WHERE outcome_id = todos.id AND role = 'current')` with no `TRIM` guard (blank Action text is unrepresentable — `ActionDao` rejects it), and every query carrying that predicate lists `actions` in `readsFrom`, so an Action written locally or landed by the sync bridge re-emits the list (ADR-0010). Only `role='current'` satisfies it: a `planned` Action is not engageable (ADR-0004) and a `superseded` one is history.

**History reads (story 8, issue #478):** the Outcome's history is its terminated rows, and `ActionDao.watchTerminatedActions` / `getTerminatedActions` are how a surface asks for them. Both filter `outcome_id = ? AND role IN ('done','superseded')` and order by `COALESCE(done_at, updated_at, created_at) DESC, id ASC` — a `done` row's terminal time is `done_at`, a `superseded` row's is `updated_at` (ADR-0018 gives it no column of its own), `created_at` catches a row with neither, and the `id` tie-break mirrors `winnerFirstOrderSql` so two devices render the same order. Each row carries the minutes logged against *that* Action, joined in as a correlated subquery (`TimeLogDao.totalMinutesSubqueryForAction`, the Action-grain sibling of `totalMinutesSubquery`) rather than fetched per row. The ordering expression looks identical to the one `TodoDao._needsReviewWhere` uses for Stale, and deliberately is not shared with it: Stale excludes `superseded`, history includes it — the two mean different things over the same columns. Like every other read here it is a pure SELECT that never stamps, converges, or notifies; reading history is not clarification. Drift tracks `actions` for re-emission and not the joined `time_logs`, which is sound because a terminated Action's logs are closed by its own terminal transition and nothing opens a log against a non-`current` row, so its minutes are frozen.

The **Abandon** affordance is the UI entry point that makes these rows appear without a completion: `TaskDetailNotifier.abandonCurrentAction` delegates to `ActionDao.clearCurrentAction` — supersession with no replacement, which retires the current Action and stamps `last_clarified_at` (unlike completion, abandoning *is* a clarifying act). It writes no cursor, and needs none: the startup sweep cannot resurrect the retired Action because it never reads the cursor. Nothing promotes, edits, or deletes a terminated row: `applyPromotePlannedAction` refuses any role but `planned`, and the history surface renders text only.

**Completion (story 4, issue #474):** `ActionDao.completeCurrentAction(outcomeId, {now})` is the transition that records *this Action* as finished: it converges any multi-current set, flips the winner to `role='done'` with `done_at`, and leaves the Outcome active and Actionless (ADR-0004 — nothing is auto-promoted). It is the single exception to the stamping rule: completion is an **engagement** signal, not a clarifying act (CONTEXT.md § Clarification), so `last_clarified_at` stays put and the Outcome immediately owes a re-clarification. Two consequences follow. First, the transaction **writes nothing to `todos` at all** (ADR-0022): the sweep cannot resurrect the finished Action, because it never reads the cursor that would tell it to. The cost is that `todos.updated_at` no longer moves on completion. Second, the `todos` view-notify therefore cannot ride on the `stamped` flag — which is always false here — and is issued unconditionally whenever anything changed. It must stay even though no `todos` write remains: two list watchers name only `{todoTags, tags}` in `readsFrom`, so an `actions`-only notification would never reach them. It is a no-op on an Actionless Outcome and idempotent on replay (a second call finds no current row, so a completion can never produce two terminal rows or push `done_at` forward).

**Outcome completion cascades into Action completion.** Achieving the Outcome means the user finished the current Action in the act of finishing the Outcome, so both write paths that set `todos.done_at` — `TodoDao.markDone` and `TodoDao.applyRouting`'s `done` arm — run `ActionDao.applyCompleteCurrentAction` inside their own transaction, sharing one apply-variant. Both keep stamping `last_clarified_at` (completing an Outcome *is* a clarifying act; the apply-variant always reports `stamped: false` and leaves that decision to the caller). `planned` rows are untouched history. Trashing an Outcome (`setIntent` trash, `applyRouting` trash) leaves Action rows entirely alone — they persist exactly as the Outcome row does.

**Freshness reads terminations directly.** With real termination timestamps in the table, `TodoDao._needsReviewWhere`'s Stale branch is the later of two independent signals, expressed as parallel ORs: `last_next_action_completion_at` (stamped once, at Focus-session close, by `FocusSessionDao` — it means "worked on in a session", history no Action row can reconstruct, and is unchanged) and `MAX(COALESCE(done_at, updated_at, created_at))` over the Outcome's `role='done'` rows. Completing the current Action therefore surfaces the Outcome for re-clarification even when no session ever closed. `superseded` rows are deliberately **excluded** from the widening: every app-side supersession stamps `last_clarified_at` with the same timestamp it writes to the retired row, so `last_clarified_at < updated_at` is never true for an honest one; the only `superseded` rows that could outrun the stamp are the non-stamping repairs (multi-current convergence, the startup sweep), and reading those as engagement would flip an Outcome Stale on repair alone. The planning hint (`isStaleReclarification` / `hintFor`, `task_review_step.dart`) mirrors only the session-history half — a termination-surfaced Outcome is by construction Actionless, which already renders as `noNextAction`, the accurate prompt after finishing an Action.

**The #469 seam.** `ClarificationService.completeCurrentAction(id)` delegates to the DAO primitive. It sits on the clarify-flow interface despite being an engagement write because it is the *trigger* of the re-clarification it feeds: the Focus "Done" flow completes the Action and then takes a verdict through `completeOutcome` / `clarifyToOutcome` / `stampClarified` on the same interface. Wiring `ActiveFocusScreen._onComplete` (today `db.todoDao.markDone(todoId)`) to that seam is #469's scope.

Completion replays safely with no new mechanism: the client uploads `PATCH /actions/{id}` `{role, done_at, updated_at}` and nothing else (there is no accompanying `PATCH /todos/{id}` — completion no longer writes the Outcome row), and `update_action` applies fields unconditionally, so a replayed payload converges to the identical row. Same-device queue consolidation collapses create+patch, so a lost-ack create replays *with* `role='done'` and the ADR-0015 upsert converges it. The cross-device create-replay-after-foreign-PATCH regression is the accepted last-arrival trade-off recorded in ADR-0015; the winner rule and the sweep self-heal it.

On-device `actions` is a PowerSync *view* over `ps_data__actions(id, data)` with JSON extraction, so the correlated `EXISTS` would full-scan the store once per candidate Outcome. The generated PowerSync schema therefore declares a local index on `actions(outcome_id, role)`; `powersync_schema_builder.dart` emits it from a per-table map and `powersync_schema_consistency_test.dart` asserts its *presence*, not merely column parity. PowerSync indexes are local artifacts recreated when the database opens — adding or removing one is not a migration and triggers no re-sync.

The residual exposure is a cursor-only change arriving from a client that predates the Actions table: it re-emits the `todos` watchers while the reads come from an unchanged Action row, so a stale subtext can render mid-session. The startup sweep does not reconcile it — no runtime code path reads the cursor at all. The cursor edit is simply ignored, permanently and by design. The Action row is the answer wherever the two disagree.

**Reconciliation sweep:** `reconcileActionsAtStartup` (`migration_service.dart`) runs at startup from `powerSyncInstanceProvider`, right after `migrateLocalInboxToCaptures` and before any watcher exists (so it needs no view-notify). It is **one cursor-free pass**, and it reads `actions` and nothing else:

- **`convergeMultiCurrentActions`.** The 0..1-`current`-per-Outcome invariant is app-enforced rather than indexed, so a cross-device race can sync in two `current` rows. This pass retires the losers by the same deterministic winner rule the writers and readers use — greatest `COALESCE(updated_at, created_at)`, tie-break smallest `id` — so every device collapses to the same row. It visits any Outcome holding more than one `current` row, whatever the cursor says, and retires rather than deletes (ADR-0018 history). It never mints a row and never rewrites an existing row's `text`, so `COUNT(*) FROM actions` is unchanged across a run. This pass outlives the cursor columns.

**Three cursor-driven arms were deleted and must not return** (ADR-0022). Two treated the cursor as authoritative: one overwrote a `current` Action's text and metadata from the cursor, the other retired *every* `current` Action whose Outcome had a blank cursor. Both were consistent only while every write path dual-wrote the cursor; the moment it stops being written they become destructive — the first reverts every Action edit at the next launch, the second retires every current Action on the device. Removing them also retired a latent hazard: a sweep-retired Action stranded its open `time_logs` row, because the sweep runs no termination hook.

The third was **cursor adoption**, which minted a deterministic-id `current` Action for a live Outcome carrying a non-blank cursor and *no `actions` rows at all*. It looked safe — mint-only, monotone, and guarded on the Outcome having no Action rows whatsoever — and it was not. Its guard assumed every role transition leaves a row behind, but `ActionDao.applyRemovePlannedAction` is a hard `DELETE` (the Remove-vs-Abandon distinction of issue #478) and is the only mutation that drives an Outcome's Action count to zero while the `todos` row survives. On a store whose cursor was populated in the dual-write era, *demote the current Action then remove the planned row* left a live cursor over zero Action rows, and the next launch minted the just-deleted Action back as `current` and synced it everywhere. Deleting the pass makes that impossible by construction, and keeps `applyRemovePlannedAction` a hard delete. **The general lesson: a guard phrased over role transitions has a hole wherever a mutation leaves no row at all.**

The accepted cost is that an Outcome created on a pre-Action client and synced in renders Actionless until the user gives it an Action. Alembic 0028 covered the Outcomes that held a non-blank cursor *when it ran*, so for those the text is not lost — it is already a `current` Action. It is a **one-time migration, not ongoing reconciliation**: an Outcome a pre-Action client creates after 0028 has run carries no cursor the server will ever read, and nothing since 0028 mints Actions from Outcome data, so it renders Actionless. That is the recorded residual, not a covered case. A separate, genuinely unrecoverable residual is the never-synced local store, whose cursor text had no server copy to derive from — an explicit exception taken inside the alpha window (ADR-0024); the general durability question it raises is open as **#534**. The pass is clarification-neutral — it **never** stamps `last_clarified_at` (ADR-0012 spirit — never auto-stamp on drift) — and idempotent, so the steady state is one read and no writes at all.

The server (Alembic 0028) backfilled one `current` Action for each Outcome whose `next_action_text` was non-blank at migration time (blank / whitespace-only / NULL mint nothing, matching the app's actionless normalisation). It ran once and has no successor pass, so it says nothing about rows created afterwards. The two origins converge on a **single** row with no reconciliation code: the id is `uuid5(NAMESPACE_URL, "jeeves://action/backfill/<todo_id>")` computed identically in Python and Dart (`backfillActionIdFor`), every field derives only from replicated Outcome data (`created_at = COALESCE(last_clarified_at, created_at)`), and ADR-0015 upsert-on-replay collapses any duplicate upload (**ADR-0019**). A matching client-side backfill ran in the Drift v26 `onUpgrade` until #525 deleted it together with the column it read (ADR-0024); the server already holds every Action it would have minted, so a client reaching v26 today re-syncs them rather than re-deriving them. `backfillActionIdFor` and its cross-language golden vector stay in the client as the contract the server backfill mints against.

#### The two-stage boundary

Sync is two stages, and the seam between them is a hard boundary:

1. **UI ↔ local storage** — widgets, providers, and DAOs read and write the local Drift database.
2. **Local storage ↔ remote** — PowerSync replicates down; `JeevesBackendConnector` uploads up.

**Stage 2 is out of scope for all UI behaviour.** The UI's contract is with the local row and nothing else. It cannot determine — and must not attempt to determine — whether a local change originated from another screen, a background job, or a replicated delete from another device. "The row is gone locally" is the complete signal; there is no UI-visible notion of a *remote* delete, and a screen reacting to a subject disappearing is doing local-storage reactivity, not sync.

The practical consequence is about how UI behaviour gets *justified*, not just how it is implemented. Writing to a row absent from local storage is incorrect on its own terms. That a stray write would also be queued, rejected by the backend, and dead-lettered is a downstream symptom which confirms the bug — it is never the reason to fix it. A UI fix argued from its downstream sync symptom will be scoped wrong, because it optimises for the connector's behaviour rather than the local invariant. UI feature code therefore does not reference `JeevesBackendConnector`, the CRUD/upload queue, `sync_dead_letters`, or backend status codes — the sole exemption is the informational status adapter below — and UI tests exercise local storage directly rather than a sync round-trip.

**Sync status is informational, never blocking.** The one stage-2 signal the UI may see is replication health, and `syncStatusProvider` is the only adapter licensed to source it: it combines PowerSync's engine status with the `sync_dead_letters` count — a non-zero count forces the error state — and feeds the app-shell indicator and the settings SYNC row, both of which only *render* it. Behaviour must never depend on it — no gating a write, disabling a control, or branching a flow on sync state. The offline-first contract is that every user action completes against local storage regardless of what stage 2 is doing. Reading sync status to decide *whether* something happens is a stage-2 dependency wearing a display read's clothing.

#### Upload-error policy

A CRUD entry whose REST upload fails is classified per status code by the pure function `JeevesBackendConnector.classifyUploadError` — never by a blanket "4xx is fatal" rule. PowerSync queue mechanics force a three-way choice: rethrowing keeps the entry queued but blocks every later upload behind it (head-of-line), so only genuinely transient errors retry; everything else must leave the queue loudly and losslessly.

| Status | Action | Rationale |
|---|---|---|
| no status (network / timeout) | retry | transient transport failure; entry stays queued |
| 401 | retry | `_AuthRetryInterceptor` (api_service.dart) already refreshed the token and retried once; a 401 reaching the connector means the refresh itself failed, so the entry stays queued for the next backoff cycle. Never dropped. |
| 408, 429 | retry | timeout / back-pressure; PowerSync's retry backoff resolves it |
| 5xx | retry | server fault, presumed transient |
| 404 on PATCH / DELETE | discard | the only auto-drop: the remote row is already gone; server deletion wins and the next pull converges local state. Logged. |
| 404 on PUT | dead-letter | e.g. a `todo_tags` link whose parent was deleted remotely — recorded, never silent |
| 403 | dead-letter | not user-actionable; recorded so the permission / RLS bug is fixed at the root |
| 409 | dead-letter | genuine client-unresolvable id conflict; per-table meaning below |
| 400, 422 | dead-letter | client bug — payload and response body persisted for diagnosis |
| any other 4xx | dead-letter | safe default: nothing is ever silently dropped |

**409 per table.** Every connector-facing POST create route dedupes by client-generated id, and a same-user replay upserts the submitted client-owned fields and returns the row (upsert-on-replay, [ADR-0015](./adr/0015-create-dedupe-upsert-on-replay.md); docs/SYNC.md § the create-dedupe contract), so a 409 is never a retry artifact (unrelated POST endpoints — e.g. sub-resource actions like `/todos/{id}/suggestions` — are outside this client-id dedupe semantics; the connector never uploads them, so they never reach the status classification above): for `todos`, `tags`, `user_preferences`, `focus_sessions`, `time_logs`, `captures`, and `actions` it means the id belongs to another user; for the junction routes (`todo_tags`, `focus_session_tasks`, `capture_outcomes`, `capture_tags`) it means the id is already bound to a different relation. No current 409 is a merge-able both-sides-edited conflict, so entries are classified and recorded losslessly; a genuine two-sided conflict-reconciliation interface is deliberately out of scope here and tracked as follow-up work coordinated with the `user_preferences` per-key strategy registry.

**Dead letters are instrumentation, not a product surface.** A dead-lettered entry is written to the local-only `sync_dead_letters` Drift table (never replicated; capped at `GtdDatabase.syncDeadLetterCap` rows, stalest last occurrence pruned first) with the operation, table, row id, payload, status, and truncated response body. Recording is idempotent per failure — one row per distinct (table, row, operation, status), refreshed on repeats — because a batch retried after a partial failure re-uploads entries that were already dead-lettered. A non-zero count forces the existing sync indicator into its error state via `syncStatusProvider`, and every dead-letter / discard is also `debugPrint`-logged with safe metadata only (table, operation, row id, status) — payloads and response bodies stay in the local table, never in console logs, which `debugPrint` emits even in release builds. There is no user-facing retry/drop surface, by design — by the time an entry fails classification it is a deterministic failure, so resolution means fixing the root cause: a 422 is a client payload bug, a 403 is a permission bug, and 404/409 churn means a route needs idempotency work. The north star is that the dead-letter table trends toward empty.

### Minimal Sync Server

PowerSync above is the production sync path and stays so until the cutover in #553. Alongside it, a second, self-contained sync stack carries the whole domain — the content-blind op log that ADR-0026 replaces PowerSync with, plus ADR-0028's trust root. **The running app still writes through PowerSync.** The op-log stack is engaged only by `app/test/sync/`; the DAO write paths describe their effects through a seam whose production binding is a no-op, so at no point does the app feed both the PowerSync upload queue and the op log — teeing writes into both would be exactly the dual-write branching the proposal's Implementation stance forbids.

- **`backend/app/sync/`** — six tables and two credentials. `ops` (append-only per Workspace, `seq BIGSERIAL` as a transport cursor only), `members` (public keys plus `chained_at`, the server's own index of which registrations landed), `recovery_escrows` (one passphrase-wrapped Root per `(workspace, user)` slot), the append-only `recovery_escrow_fetches` audit, and `workspaces` plus `grants` — the server's own index of which Workspaces exist and who holds what in them, authoritative for nobody as described below. The **User credential** reaches `POST /members`, `PUT`/`GET /w/{w}/recovery` and the proof-of-possession exchange; a **member-scoped token**, issued only against an Ed25519 signature over `"jeeves/auth-challenge/v1" ‖ member_id ‖ nonce`, reaches `POST`/`GET /w/{w}/ops`, `GET /w/{w}/members` and `WS /w/{w}/signal`. `resolve_member_token` is the single site that resolves all of them, HTTP and socket alike, so the socket cannot become the weak door: a user session subscribes to nothing. `get_current_user` refuses a member token and vice versa, and every posted op must name the token's own Member as its author — one comparison, no crypto (F10). The separation holds for **refresh** tokens too, and in both directions: a refresh token is a row rather than a JWT, so `POST /session/refresh` refuses any record carrying a `member_id` and `POST /members/{m}/token/refresh` refuses any record without one — otherwise a Device would launder its member refresh token into a full user session and from there into the escrow. `POST /members/{m}/challenge` is unauthenticated on purpose (possession of the device key *is* the credential being proved) and therefore rate-limited: a per-member-id Redis counter capped by `MEMBER_CHALLENGE_DAILY_LIMIT` over `MEMBER_CHALLENGE_WINDOW_SECONDS`, checked after the existence lookup so id enumeration creates no counters, refusing with `member_challenge_rate_limited`. Both op uniqueness rules — `(workspace, author, op_id)` and `(workspace, author, author_seq)` — are database constraints, because the handler reads `MAX(author_seq)` before it inserts and two concurrent batches would otherwise fork an author's chain; a raced insert comes back as the idempotent duplicate or a 409, never a 500. Alembic `0031` adds the log and registry, `0032` the escrow and the identity columns, `0033` the `workspaces` and `grants` index; none join the PowerSync publication.
- **`app/lib/sync/`** — the v1 envelope and control-payload codecs, HLC, `RootAuthority`, the recovery-escrow blob codec, `PassphrasePolicy`, `EnrolmentService`, the `DeviceKeyStore` seam (Keychain/Keystore in production, in-memory in the harness), a client-owned Drift store (`op_log`, `outbox`, `author_state`, `sync_cursors`, `quarantined_ops`, `integrity_alarms`, `root_pins`, `control_chain_state`, `applied_control_log`, `epoch_floors`, reduced state), the field-grain reducer with a collection registry, the per-author chain verifier, `SyncClient` over the two transport seams, and `SignalSocket`/`SignalListener` for the subscription. Plus the four pieces that carry the domain across it, described below: the capture seam, the per-collection codecs, the merge-strategy registry, and the domain projector.
- **`spec/sync/`** — frozen golden vectors. `envelope_v1_vectors.json` pins the header at every field offset, the body framing and padding rules, all seven signing domains, the genesis, MemberRegister, Grant and Revoke certificates with their chain links, the escrow and challenge signature preimages, the Argon2id floor, and every fail-closed refusal; `reducer_v1_vectors.json` pins the merge rules, including the non-LWW strategies' lattice behaviour — a case may carry `permute` (the runner applies the ops in every order and expects identical reduced state) and `expected_clocks` (the stored per-field HLC, which a values-only case cannot observe). Both suites assert byte equality against the same files and neither regenerates them — `backend/tools/generate_sync_vectors.py` is run by hand, and re-running it is a protocol change.

**Content is opaque; control is not.** The server reads the 158-byte header for its index columns and its content-blind authz, and never a content body. `op_class = 2` is the deliberate exception (ADR-0028, F2): control payloads are unencrypted *so that* membership can be checked before it is materialised, and that is the only body-reading path in the routes.

**The signal socket is the one push in the stack, and it carries nothing.** After the client sends its member token as the first frame (a browser cannot set `Authorization` on a WebSocket, and a query string would log the token), the server answers with a **poke** — a zero-length text frame meaning "run a sync from your cursor now" — and sends nothing else but that poke and the fixed keepalive literal `ping`, emitted only while the socket is idle. The Workspace is in the URL path, so no frame carries a seq, an author or a count, and coalescing is free: N appends before the subscriber wakes collapse into one poke, and the pull sweeps up everything past the cursor. The handshake's immediate poke doubles as the auth ack and the catch-up trigger, which is why the server keeps no per-subscriber state at all. The handshake is also the only part of a socket's life that holds a database session; it is released before the pump starts, because a session kept for the connection's lifetime parks a pooled connection idle-in-transaction per subscriber and starves HTTP once the pool is exhausted. Refusals close the socket: 4401 bad or non-member token, 4403 no grant, 4400 no auth frame within the deadline. Fan-out is `SignalHub`, in-process and single-worker by construction (see BACKEND_GUIDELINES.md §6 and §8). On the client, `SyncClient` stays a verb-set and `SignalListener` owns the subscription lifecycle: a poke means a pull — no directory refresh precedes it, because a MemberRegister is its author's op 1 and the pull hydrates the directory in `seq` order by itself — single-flighted with a dirty flag; a lost, silent or misbehaving socket rides an exponential backoff with full jitter; 4401 parks until the token refreshes; 4403 is terminal.

**The trust root.** Root is a random Ed25519 keypair, never derived from the passphrase, living at rest only inside the escrow blob and held by a Device just long enough for an enrolment ceremony or a passphrase change. A Device registers itself with a `member_register` control op — its own `author_seq = 1` — carrying a Root-signed certificate; Root never authors an envelope. Clients pin `root_pk` on first successful unwrap (TOFU against the passphrase, not the server) and their member directory is **chain-gated**: a key is learned only from a MemberRegister the device verified itself, in six steps — parse, Root signature over the literal certificate bytes, certificate-names-this-author, envelope signature *against the certificate's key*, key-id match, then position and chain. `GET /w/{w}/members` is a bootstrap hint that verification never reads, so poisoning it is inert — and no client calls it at all: `MemberDirectory.rememberChained` takes a parsed certificate, so there is no code path by which the registry could populate the directory, and neither transport interface carries a read for it. The route stays because the server's own content-blind authz needs the index; if a client ever needs the read it belongs on `SyncTransport`, since the route requires an unrevoked member JWT. Ops from a Member with no verified registration quarantine as `member_not_chained_to_root`, and terminally: the release scan below re-admits chain-gap refusals only, so an unchained author's content stays refused.

**Workspaces, Grants and roles.** A User has two implicit Workspaces, each a `uuid5` derivation of the user id — the default GTD one and a User-global `user_preferences` one — and each brought into being by a `workspace_genesis` control op. Genesis **embeds its founding Device's registration**, because the founder's key is unknowable before the certificate parses and there is no earlier op to learn it from (ADR-0031); an all-zero `prev_control_hash` is genesis-only in both directions, so a truncated history is always detectable. Genesis authorship is *log-state-conditioned*: any device holding Root founds a Workspace whose control log it observed empty, which is what makes the ceremony's crash window recoverable. Observing an empty log enters the race rather than winning it, so two Root-holders can both author one; the server admits exactly one and answers the loser `genesis_not_first`, including when the interleave is only caught by the `workspaces` primary key at commit. That 409 is neither an accusation nor a wedge on the client: the queued genesis can never become acceptable, so it is dropped, the Workspace's author chain is rewound to what the log attests, and the ceremony takes the *other* branch of the same method — pull the winner's genesis, register into it. Losing costs one extra iteration and no extra code path. Membership is then `grant`/`revoke` control ops carrying granter-signed certificates under their own signing domains, with roles **owner | participant | compactor | suggester**; revocation is grant-granular. An `owner` Grant is Root-mint *and* Root-revoke — the symmetry is ADR-0031's — so revoking a Device takes the passphrase. Both halves of that ceiling are judged against the batch's own in-memory walk of the `grants` index rather than the table, so a Grant minted at index 0 of a POST counts for a revoke at index 1 of the same POST; the revoke half needs it, because a frozen revoke certificate names a `grant_id` and not a role. A `grant_id` is single-use — a *different* op reusing one is a 409 rather than a primary-key collision — and because control verification runs before the append resolves duplicates, the already-stored op ids are passed down and exempted, so an idempotent re-POST of the enrolment batch is a replay and not a reuse.

Authorization splits three ways on the server. The escrow routes take the User credential and admit either derivable Workspace. `GET /w/{w}/ops`, `GET /w/{w}/members` and the signal handshake admit any **unrevoked** member token whose User derives the Workspace, with no Grant required — that is what lets the ceremony pull the control log before it holds one, and a pre-genesis GET returns an empty page rather than an error. Content POSTs require a **live Grant** and dispatch on `(grant.role, header.op_class)`; a root-signed control payload lands regardless of Grants, which is how an ungranted device's register-plus-grant batch gets in. `workspaces` and `grants` are the server's own index, authoritative for nobody: a client derives its grants view from its applied control log and evaluates the verdict **at the op's own server seq** (`granted_seq < S < revoked_by_seq`), never against current state, so a late-arriving pre-revocation op still applies. Revoking a Member's last live Grant kills its refresh tokens *and* closes its live signal sockets, since a socket is authorised once at the handshake and never re-checked. A control fork is resolved by earliest certificate HLC then lowest author member id — the certificate's clock and not the op's, or a forking author could move the tie by re-signing an envelope around the same certificate — and the losing branch is quarantined along with every control op chaining through it. Because that can change which content ops were authorized, resolution triggers a full **rebuild from the op log** — the reduced state is a join-semilattice with no per-seq lineage, so there is no partial rewind — recomputing only the authorization verdict, honouring persisted `refused_reason` for reducer-guard refusals, and clearing a stale `no_live_grant` off an op the corrected view now admits. The rebuild reports every entity it touched **plus every entity that had reduced state before it started**: an entity whose ops all became refused reduces to nothing, so the replay names it nowhere, and a projector told only about what re-applied would leave its domain row standing as the last visible trace of a quarantined branch.

**Per-author chains are verified, and a misbehaving server is an alarm rather than data weirdness.** Every content op's position is checked against its author's **verified head**, derived from `op_log` at read time and never stored — a stored head would be a cache of the log, free to disagree with it. The verdict sits after `verifyEnvelope` and after the payload decodes, because only an authentic *and* codec-valid envelope may advance or accuse a chain; the append is a plain insert and never an upsert, so a slot already taken — the transport's `(workspace, seq)` primary key or the `(workspace, author, author_seq)` unique index that mirrors the server's constraint — is refused rather than written over: a server spending one `seq` on two different chain-valid ops raises `author_chain_slot_collision` and the second op is skipped, because the log is evidence and evidence is not edited. Any *other* database failure on that append propagates and aborts the pull with the cursor unmoved, so a transient error is an op the next sync retries rather than one permanently skipped under a collision label it never earned. Everything else that escapes the receive pipeline un-classified — a parse, verify or decode path throwing something that is not a `SyncRejection` — is quarantined as `unexpected_receive_failure` rather than propagating, because an error thrown before the cursor advances would have every later pull refetch and re-throw on the same op: fail-closed has to be total, or one adversarial envelope wedges the receive indefinitely. `op_log` admits every chain-valid envelope even when a reducer guard then refuses its payload, marking the row with `refused_reason` and leaving `applied_at` null — withholding it would make the author's honest next op read as a gap — and `_clock.receive` fires only on a successful apply, so a refused future timestamp cannot poison the local clock. Two vocabularies come out of it: a **quarantine reason** per refused envelope (`author_chain_gap`, `prev_author_hash_mismatch`, `author_chain_rewrite`, `duplicate_op_id_divergence`, `stale_replayed_op`, `own_writes_divergence`, `unexpected_receive_failure` — client-only codes, since a chain rule is stateful receiver policy rather than a codec rule, so no golden vector carries one) and an **integrity alarm** per standing accusation, upserted by `(workspace, kind, author)` so a server re-serving the same evil bumps a counter instead of flooding rows — a unique index, not merely a convention the writer honours, except for the server-only alarms that name no author, which SQLite's distinct-NULLs rule leaves to the select-then-write path. Both that index and the chain-slot one are created behind a **pre-flight duplicate check** that fails the migration with the invariant and the recovery named, because the alternative — de-duplicating the rows first — would edit the evidence to let a schema change through, and because no store the server has ever seen predates the #553 cutover: the affected stores are dev and harness stores, which are disposable. Reorder heals to fixpoint: each accepted op re-asks whether the op at head + 1 is in quarantine, in one flat loop with re-entry suppressed, and a released row keeps its `released_at` for inspection. A gap alarm is reclassified to `author_stream_reordered` only once no unreleased gap row remains for that author; a predecessor that arrives and does not match is `author_chain_fork` and stays refused. So drop, reorder and fork end in three distinguishable states, and withholding stays detectable rather than preventable. The pull cursor never regresses, staleness is judged against the `since` the page asked with (an op above it arriving out of order is a reorder, not a stale prefix), and a page with no forward progress ends the pull. The flush posts the queue in `maxOpsPerBatch` chunks in `author_seq` order, each acknowledged before the next goes out — the one number the server's `MAX_OPS_PER_BATCH` mirrors, exported so the two cannot drift, since a device that authored more than the cap offline would otherwise re-POST the same oversized batch for ever and never drain the queue the outbox exists for. Authoring is serialised for a related reason: the chain head is read before the envelope is signed and advanced after, so two un-awaited `capture()` calls would both mint an envelope at one `author_seq` — a fork this device signed against itself, which no constraint catches, because the `(workspace, author, author_seq)` unique index guards `op_log` and neither `outbox` nor `author_state` holds that key. A 409 on our *own* POST is judged against the retained outbox: `own_writes_rollback` when the server's expected position is at or below what it already acknowledged (the detail names both possible causes — a rolled-back server, or this device restored from an older backup — because the client cannot tell them apart), fail-closed with nothing re-numbered, and the flush wedge never blocks the pull. `SyncHealth` reports it: `clean` is derived from `pending_op_count == 0 && unresolved_alarm_count == 0`, so it cannot read clean over a stuck queue or a standing accusation. A chain gap covered by a verified prune op will not be an alarm — the verdict already takes an optional verified floor `({seq, envelopeHash})` that substitutes for an absent head, dormant until #555 supplies one.

Protocol identity: envelope = 158-byte header ‖ body ‖ 64-byte Ed25519 signature, with AAD defined as the literal header bytes so the `aead_v1` swap (#554) changes only the body; body = `u32 payload_len` ‖ JSON ‖ zero padding to `{256, 1024, 4096, 16384}` or, above that, the next 16 KiB multiple; suite `0x00` = `plaintext_v1`; op classes 1–5 named, `1=content` and `2=control` served, everything else fail-closed on both sides. Control ops chain across authors by SHA-256 over the predecessor's *payload bytes*, which is why every control payload must carry a `type`. Seven domain-separated signing prefixes, one per document a signature can be over: `jeeves/op/v1`, `jeeves/member-register/v1`, `jeeves/auth-challenge/v1`, `jeeves/escrow/v1`, `jeeves/workspace-genesis/v1`, `jeeves/grant/v1`, `jeeves/revoke/v1` — a new certificate kind gets its own prefix rather than sharing one, so a signature over one document can never be replayed as a signature over another. Ordering is HLC `(wall_ms, counter, member_id)` — `seq` is never a merge input. Deletion is a tombstone op. Every route rejection carries a structured `{"code": …}` detail, with the batch `index` on per-op failures.

Stubs still left for the siblings: `rotate` and the remaining control types (#554 — `unsupported_control_type` is their landing slot; `epoch_floor` is persisted, monotone and consulted on authoring, but nothing raises it in anger yet, and the *orphaned grant* predicate is defined against epoch 0 and never fires); alarm **UI** — the streams `watchIntegrityAlarms()`, `watchSyncHealth()` and `watchQuarantineCount()` are the surfacing seam and this stack ships no widget over them; cross-author fork detection, which needs `observed_head` (still zeroed) and author heartbeats, so author silence stays indistinguishable from offline; the live-app cutover, including the enrolment and passphrase *screens* (#553 — the logic and its service API are here); KeyWraps and AEAD (#554 — `master_wrap_key` is escrowed and read by nothing); and compaction/prune (#555; `ops.compacted_by` exists and is unused). PowerSync removal and the dead-column drop ride #556.

#### Two stores, and the path between them

Every device holds **two** stores, by design. The `SyncDatabase` is the collection-generic convergence substrate — reduced fields, per-field clocks, tombstones, the received log — and it is what "byte-identical convergence" is measured over; a device that has not shipped a feature still reduces its peers' writes rather than losing them. The `GtdDatabase` stays the domain read model. Reduced state reaches it through a projector, never the other way round.

| Piece | File | Role |
|---|---|---|
| Capture seam | `app/lib/sync/domain_op_capture.dart` | What every DAO write path describes its effect through. Buffered per transaction and coalesced per entity, so a rolled-back write is never signed and a method that touches one row three times authors one op. Each scope carries its own buffer and is closed by the token `beginScope` returned, not by stack position — two overlapping un-awaited `capturing` calls must not be able to close, or flush, each other's scope. A scope whose parent is already closed overlapped rather than nested, so it flushes on its own. Production binding is `NoopDomainOpCapture`; #553's flip is `GtdDatabase(..., opCapture: SyncOpCapture(client))` at one construction site. |
| Per-collection codecs | `app/lib/sync/collection_codecs.dart` | Twelve collections named after their tables, their synced columns, and the one canonical value encoding. |
| Merge strategies | `app/lib/sync/merge_strategy.dart` | ADR-0011's Conflict Strategy registry riding on the reducer, behind the ADR-0030 lattice requirement. |
| Domain projector | `app/lib/sync/domain_projector.dart` | Turns reduced state into typed rows, once per pull batch, and fires the ADR-0010 self-notifies. |

**Value encodings are protocol surface.** Drift `dateTime` columns encode as an ISO-8601 UTC instant truncated (never rounded) to exactly three fractional digits with a trailing `Z`; TEXT timestamp columns pass through byte-for-byte as opaque strings; text, int, bool and null pass through as JSON natives. #553's reseed uploader reuses these codecs, so it cannot emit anything else.

**Entity ids.** Normal collections keep client-random UUIDs. Two exceptions, both deterministic: `user_preferences` derives its id from `(workspace, key)`, and **junctions derive theirs from their pair** — `todo_tags`, `capture_outcomes`, `capture_tags`, `focus_session_dispositions` already did, and `focus_session_tasks` joins them via `focusSessionTaskIdFor`. A junction's domain identity *is* the relation, so two devices assigning the same tag offline converge as one entity instead of forking. Where the local `id` column is not the derivation (`focus_session_tasks`, `user_preferences`), the projector realigns it on every device.

**No implicit cascades.** The log has no foreign keys, so every deletion enumerates its cascade set at capture time. `deleteOutcome` — the one hard-delete path, reached only by the clarification-retraction orphan gate — tombstones the Outcome, its Actions, its `todo_tags` and its `capture_outcomes` links, and nulls `time_logs.action_id`. That is deliberately *wider* than the shipped local delete, which left the rest to the server's `ON DELETE CASCADE`; on the authoring device the projector applies the widened set. Time data is never destroyed: a TimeLog outlives its Outcome and renders as *elsewhere*. Trash is not a delete — it is a plain `intent` field write on a live entity.

**`SyncHealth`** (`app/lib/sync/sync_health.dart`) is the replacement for the PowerSync status indicator: queue depth, unresolved integrity alarms and their kinds, quarantine count, and a `lastSyncedAt` stamped on **pull completion, independent of flush state**. `clean` is a derived getter, never a stored status — a wedged outbox shows through `pendingOpCount`. `SyncHealthIndicator` renders it; #553 swaps `syncStatusProvider` for it, and the dead-letter machinery does not carry over.

## Platform I/O Adapters

Any code that opens a file, spawns a process, or calls a native OS API must be isolated behind a platform adapter using Dart's conditional import mechanism. This keeps `dart:io` out of shared provider and service code so the app compiles cleanly on web without `if (kIsWeb)` branches scattered through business logic.

### The pattern

Three files per adapter:

| File | Compiled on | Responsibility |
|---|---|---|
| `*_stub.dart` | Neither (analyser only) | Throws `UnsupportedError` — gives the analyser a type to resolve on all targets |
| `*_io.dart` | Native (dart:io) | Concrete native implementation; may import `dart:io`, `path_provider`, etc. |
| `*_web.dart` | Web (dart:html) | Concrete web implementation; may import `package:powersync/web.dart`, `dart:js_interop`, etc. |

The entry-point file uses a conditional export to pick the right implementation:

```dart
export '*_stub.dart'
    if (dart.library.io)   '*_io.dart'
    if (dart.library.html) '*_web.dart';
```

**Rule:** any new platform-specific I/O must follow this pattern. Never add `if (kIsWeb)` branches inside provider or service code — put platform divergence in the adapter file.

### Current adapters

#### `app/lib/database/powersync_storage.dart`

Opens the process-wide `PowerSyncDatabase`.

- **Native (`powersync_storage_io.dart`):** resolves a file path via `path_provider`, runs the one-shot legacy-table migration, and opens `PowerSyncDatabase(schema, path)` using the native SQLite library (`sqlite3_flutter_libs`).  This path is shared by Android, iOS, macOS, Linux, and Windows — a platform gaining divergent behaviour (e.g. encryption key from Keychain) should split its own adapter rather than branching inside `powersync_storage_io.dart`.
- **Web (`powersync_storage_web.dart`):** opens `PowerSyncDatabase.withFactory(WebPowerSyncOpenFactory(path: 'jeeves'), schema)` backed by OPFS in Chrome and IndexedDB in other browsers.

#### `app/lib/services/platform_helper.dart`

Detects whether the app is running inside an Android emulator (for API host rewriting).

- **Native (`platform_helper_io.dart`):** reads `Platform.isAndroid` from `dart:io`.
- **Web (`platform_helper.dart` stub):** always returns `false`.

### Web worker assets

`WebPowerSyncOpenFactory` requires two files to be present in `app/web/` at runtime:

| Asset | Source |
|---|---|
| `sqlite3.wasm` | PowerSync GitHub release for the pinned `powersync` version |
| `powersync_db.worker.js` | Same release |

These files are **not committed** (`app/.gitignore`).  Run `make setup` (or `tool/fetch_web_assets.sh` directly) to download them.  The script reads the exact version from `app/pubspec.lock` so the assets always match the Dart package.

### COOP / COEP headers (OPFS requirement)

OPFS and `SharedArrayBuffer` require [cross-origin isolation](https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/SharedArrayBuffer#security_requirements).  The server must send:

```text
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

- **Development:** `flutter run -d web-server --web-header "Cross-Origin-Opener-Policy: same-origin" --web-header "Cross-Origin-Embedder-Policy: require-corp"`
- **Production:** configure in the reverse proxy or CDN in front of the Flutter web build.

## Focus Mode Execution

Focus Mode is the task execution layer activated after daily planning. Its architecture separates ephemeral timer state from durable task state.

### Routing

`/focus/active` is a top-level `GoRoute` registered **outside** the `ShellRoute`, so `AppShell` (drawer, navigation) is not rendered. The user sees only the active task. `/focus` (the daily plan list) remains inside the `ShellRoute`.

The router has a `redirect` callback only for SWS mode (redirect `/register` to `/login`). `/focus` is unconditionally accessible from the drawer (entry labelled "Now" — the execution home's user-facing title; internal identifiers stay Focus, see CONTEXT.md); daily planning is entered explicitly via the "Plan the Day" button on the Focus screen or the amber `FocusSessionPlanningBanner` in `AppShell`. `/focus/active` is reached from the execution home's Start buttons and from the task detail screen's "Start focus" affordance, which engages the task with or without an open session (see `FocusModeNotifier`).

### Top-level routes outside the ShellRoute

| Route | Screen | Purpose |
|---|---|---|
| `/inbox/:id/clarify` | `InboxClarifyScreen` | Standalone clarification for a single inbox item; tapped from an inbox row |
| `/task/:id` | `TaskDetailScreen` | Full task detail view; reachable from Next Actions, search results, etc. |
| `/focus/active` | `ActiveFocusScreen` | Active focus timer |
| `/focus-session-planning` | `FocusSessionPlanningScreen` | Daily planning ritual |
| `/shutdown` | `ShutdownRitualScreen` | End-of-day shutdown ritual |
| `/settings` | `SettingsScreen` | App settings |
| `/search` | `SearchScreen` | Universal search |
| `/import` | `ImportScreen` | Data import |

Ceremony routes (`/focus-session-planning`, `/shutdown`, `/periodic-review`) are entered via stackless navigation (`context.go`, notification deep-links, the nudge banners), so there is no in-app back stack to pop into. Each ceremony screen wraps its wizard in `CeremonyPopScope` (`app/lib/widgets/ceremony/ceremony_pop_scope.dart`), which gives system back well-defined semantics: it invokes the exact Back callback the active step's footer renders (retreating the per-item cursor first, then the step); when that callback is unavailable (first step, first item — or a completion screen) it exits to the execution home (`context.go('/focus')`), never to the launcher. Exiting mid-ceremony abandons the performance — the screen's dispose fires `CeremonyInProgressNotifier.exit()` (deferred to a microtask, since unmount runs while the tree is locked).

### Inbox row tap flow

Tapping an inbox row navigates to `/inbox/:id/clarify` (`InboxClarifyScreen`), a focused, full-screen clarification flow.

`InboxClarifyScreen` is a **host**, not an implementation. All three clarify surfaces render one body, `ClarifyCard` (`app/lib/widgets/clarify_card.dart`):

| Surface | Host | Owns |
|---|---|---|
| Ceremony Clarify Inbox step | `ClarifyStep` (`app/lib/widgets/ceremony/clarify_step.dart`) | the wizard's own footer (Back / Skip) |
| `/inbox/:id/clarify` | `InboxClarifyScreen` | `PopScope`, `AppTitleBar`, Skip, `pop()` |
| Re-clarify sub-flow | `ReclarifyRoute` (in `process_to_handlers.dart`) | `AppTitleBar`, `pop(action)` |

The card renders **no chrome** — no `Scaffold`, no `AppBar`, no `PopScope` — and never pops. Every exit is a host's, which is what lets one widget serve three of them. What the hosts genuinely differ in is one option and three composition slots:

- `ClarifyTagSection` — `editablePickers` (the ceremony surfaces: project and context pickers whose edits persist as tag hints, watched live so the chips re-render) or `draftInputOnly` (the standalone screen: no tag section, and the hints read exactly once via `CaptureDao.tagHintsForCapture` as draft input for the new Outcome). Rendering and read strategy are one enum on purpose: a surface with no chips has nothing on screen for a stream to keep in step, and a live drift `watch()` from a widget leaves a pending timer.
- `footer` — the card's last child, below the action bar. `InboxClarifyScreen` puts Skip there; Skip is a nav escape hatch rather than a verdict, so it has no place in the routing bar. It renders in both clarify modes: in n-m, leaving mid-split is ordinary use and the Capture keeps whatever Outcomes it has carved.
- `missingCta` — the way out of the subject-is-gone state, for hosts reached as their own route. The ceremony host passes none: its step footer already owns Skip.
- `onProcessingChanged` — the bar's in-flight state, mirrored out so a host can shut the escapes *it* owns. `InboxClarifyScreen` uses it for Skip, the app-bar back arrow, the pinned capture action and its `PopScope`.

The body itself, shared by all three: the clarifying-question prompt, title and notes fields, energy picker, time-estimate chips, due-date row, and the canonical `ProcessToHandlers` action bar. The Outcome-creating routes are gated on a non-blank title (`disabled`, with an inline `errorText`); **Discard stays enabled while blank** — an unnamed fragment is exactly what a user wants to throw away. In n-m mode the card renders no fields of its own at all — the whole body is `CaptureOutcomesSection` (see "The n-m clarify surface" below).

Draft assembly is one pure function, `ClarifyDraft.assemble` (`process_to_handlers.dart`), which owns three rules: a blank title nulls the whole `ActionDraft`, person tag hints never travel onto the Outcome, and the due date is truncated to a calendar day.

The shared UI primitives (`ClarifyFieldLabel`, `ClarifyEnergyPicker`, `ClarifyEstimateChip`, `ClarifyDestinationButton`) live in `app/lib/widgets/clarify_shared_widgets.dart`. The planning wizard's `InboxClarificationStep` and the periodic-review wizard's `ZeroInboxStep` both delegate to `ClarifyStep` — literally the same class in both ceremonies — which wraps `ClarifyCard` with inline loading/empty/completion branching, accepting ceremony-specific state (nav cursor, routings, callbacks, retention store) as constructor arguments with no hard-coded provider dependency. The completion view is the canonical `_InboxCleared` widget hard-coded inside `ClarifyStep`: the "Inbox is clear" frame is identical across ceremonies and is not parameterised.

#### What clarification writes, and when

**A Capture's `title` and `notes` are never written by a clarify surface** (ADR-0023). A Capture is the raw record of what was captured; clarification produces structure from it rather than editing it. The fields seed from the row and feed the Outcome draft. Tag hints are the exception `CONTEXT.md` already blesses — they persist immediately to `capture_tags`, because a hint is a suggestion recorded alongside the fragment rather than a rewrite of it. Energy, time estimate and due date have no column on a Capture at all (ADR-0006) and ride the same draft.

Because nothing persists a Capture's text, the in-progress draft is held in memory by `ClarifyRetention` (`app/lib/widgets/clarify_retention.dart`, behind `clarifyRetentionProvider`), keyed by Capture id. The ceremony hosts pass it down as a constructor argument — not looked up, so the card can stash from `dispose()` where `ref` is unusable, and so a host that should not retain says so by passing nothing. An entry survives Back, forward, step crossings and abandon-and-resume within a Ceremony performance; it is discarded at that Capture's verdict, at `startDay` / `reEnterPlanning` / `completeReview`, and at process death. Skip does not discard it. `InboxClarifyScreen` and `ReclarifyRoute` receive no store: their only exits are deliberate leaves, so there is no in-flow navigation to protect.

**An Outcome's text saves on focus loss**, the same rule `TaskDetailScreen` and `ActiveFocusScreen` use — editing an Outcome is ordinary editing. `ClarifyCard`'s `dispose()` backs that up on the Outcome shape alone, for the case focus loss cannot cover: a route popped while a field still holds focus tears the focus scope down without notifying the listener. Energy, estimate and due date save immediately on that shape. An emptied notes field travels as `clearNotes`, not as `''`: `null` reads as "no change" to the DAO, and every `notes == null` read treats an empty string as "has notes".

#### Live subject binding

All three surfaces bind to their subject live — `.forCapture` through `captureProvider`, `.forOutcome` through `taskDetailTodoProvider` — and reconcile on every emission rather than seeding once. Reconciliation is per field and respects local edits: a field whose content still matches its `_baseline*` marker (seeded from the row, adopted from a later emission, or written back to it) is *clean* and takes the incoming value; anything else is an edit in progress and is left untouched. A retained draft re-seeds through the same rule (`RetainedClarifyDraft.seedFrom`), carrying the baseline it was typed against — a dirty field keeps its **stale** baseline, which is what restores its dirty state so the live listener keeps leaving it alone for the card's life.

Every subject-bound surface — the clarify card and `TaskDetailScreen` — renders through `AsyncSubject`, the single-row counterpart to `AsyncList`. It splits the nullable subject into the four states it can actually be in, because `value == null` conflates two unrelated ones: *loading* (local storage has not answered) shows a spinner; *error* shows the shared `ErrorSurface`, never the raw exception; *missing* (`AsyncData(null)` — local storage answered, and there is no such row) shows the missing-item surface instead of the editable body, so a vanished item cannot be routed or written to; anything else is data. An error is checked before absence, so a failed query carrying a previously-null value is never mislabelled as a delete. `AsyncList` and `AsyncSubject` render the same three non-data surfaces from `state_surfaces.dart`, so a list with no rows and a subject whose row is gone look identical — to the user they are the same thing. The missing surface carries a way out wherever the surface is its own route (`InboxClarifyScreen` → Back to Inbox, `TaskDetailScreen` → Go back), supplied through `missingCta`; the ceremony host passes none. All of this is reactivity to local storage and nothing more: a subject-bound surface reads a local row and has no way to tell a change made on this device from one replicated in, and does not try — which is also why the missing surface says the item is gone without claiming to know why.

#### The n-m clarify surface

`clarify_mode` (§ Synced preferences) selects which verdict UI the two Capture clarify surfaces render. It is a preference over the *same* many-to-many storage, never a storage change: toggling it mid-stream leaves every existing row valid.

Both modes route through the same `ProcessToHandlers` bar and differ by two parameters, not by a fork.

**Destinations are the same three in both modes** — Next Action / Waiting For / Someday. `ProcessAction.done` is withheld on a Capture (an Outcome captured already-complete is a contradiction; completing one belongs on its own surface), and `ProcessAction.trash` survives only as the Capture-level **Discard Capture** verdict. Withholding them is `except:` on the shared widget, so the Capture-scoped verdict lands in the slot they vacate and inherits the routing buttons' inset, height, gap and radius from the same parent rather than from a hand-matched copy. `ProcessAction.completeCapture` — the **Done with this Capture** verdict — is a Capture-only terminal action that calls `completeCaptureClarification`: it stamps `clarified_at`, creates nothing, and maps to no `RoutingKind`, because it picks no destination.

**In 1-1 mode** `CaptureSubject.completesClarification` is true: each routing verdict calls `clarifyCaptureToOutcome` (create, link, stamp) and the Capture leaves the Inbox on the first one. The verdict slot therefore only ever reads "Discard Capture".

**In n-m mode** both surfaces replace their whole body with `CaptureOutcomesSection` (`app/lib/widgets/capture_outcomes_section.dart`), and `completesClarification` is false:

- **The Capture is read-only.** In this mode it is provenance — the record of what was thought — and the editable fields describe the *Outcome*. The section renders the Capture's text and capture date, then the Outcomes it has yielded, then the call to add another, which swaps in place for the New Outcome form.
- **One field does both gestures.** Typing in the form's Outcome field runs `TodoDao.searchOutcomesByTitle` (case-insensitive substring over live Outcomes — trashed and achieved ones excluded, LIKE wildcards escaped). Picking a match calls `mergeIntoOutcome` and closes the form over it — the merge is the whole act, so there is nothing left to route. An Outcome the Capture already claims is dropped from the suggestions. Otherwise what was typed names a new Outcome, and routing it calls `carveOutcome` with the form's full draft (notes, tags, energy, time estimate, due date) plus the chosen destination. There are no separate "new" / "link existing" affordances, because split and merge are the same gesture.
- **Neither write stamps `clarified_at`.** That is the whole difference from 1-1 mode: the Capture stays in the Inbox while Outcomes accumulate against it, and carves accumulate rather than overwriting. Routing collapses the form into a list row carrying that routing, and the call to add reappears beneath it.
- **The form auto-opens while the list is empty**, so the first Outcome never costs an extra tap; the call to add appears only once there is at least one row. An empty list renders nothing at all — no header, no empty state.
- **The verdict tracks the list, never the form.** "Discard Capture" (`discardCapture`) while the list is empty, even with the form filled in — a half-written Outcome is not a linked one — and "Done with this Capture" (`completeCaptureClarification`) otherwise. Neither opens a confirmation dialog.
- **Retraction cuts by provenance.** The section tracks which Outcome ids it carved this session; retracting one of those passes `deleteCarved: true` and the Outcome is deleted, while retracting anything else only detaches. The delete stays gated on no *other* Capture claiming the Outcome (`_retractClaim`, shared with the re-route/discard cleanup), so one Capture's undo can never destroy another's merged work. Session-scoped by necessity: once written, a carved and a merged Outcome are the same `todos` row.
- **The row shows the Outcome, its next action and its Contexts.** `CaptureDao.watchCarvedOutcomes` (via `carvedOutcomesProvider`) returns each linked Outcome with its Context tag names and the number of Captures claiming it; more than one renders a "from N Captures" chip.

The ceremonies reach the verdict through `ClarifyCard`'s `onCaptureCompleted` callback, wired by `ClarifyStep.onAfterComplete`. It is deliberately separate from `onAfterRoute`: the n-m verdict picks no destination, so there is no `ProcessAction` to report and no routing for the ceremony to record for its "previously selected" affordance. Both hooks discard the Capture's retained draft — the verdict has landed, so the interpretation now lives on an Outcome. On the Outcome shape, `onAfterRoute` runs the pre-verdict text save and the host's hook on separate error boundaries, so a failure in one is never reported as — or hidden by — the other; on a Capture the first boundary has nothing to guard.

`ClarifyCard` has two named constructors matching the ADR-0006 split: `.forCapture` (an Inbox Capture on its first pass) and `.forOutcome` (the re-clarify sub-flow). On a Capture the card unconditionally mirrors the live title into the draft's current-Action text when the user routes to Next or Waiting For — a first clarification has no deliberate phrase to lose, and `clarifyCaptureToOutcome` applies it as it mints the Outcome. On an Outcome the mirror is guarded: the title is written only when the Outcome is Actionless (no `current` Action row), so a previously-written phrase is not clobbered by a re-clarification touch. The guard is **atomic** — the card makes a single `TodoDao.setCurrentActionTextIfActionless` call (issue #501), which performs the actionless check and the mirror write in one transaction; it replaced a read-then-write across two awaits, whose window a `current` Action landed by sync could slip through to be silently overwritten.

The card's Tags section (above Energy) edits the **categorisation axes** only: a single project tag via `ProjectPickerWidget` and multiple context tags via `ContextTagPickerWidget` — the same pickers the task-detail screen uses. Both autosave through `TaskDetailNotifier` (`assignProject`/`clearProject`/`assignContextTag`/`removeContextTag`), which mutate only the `todo_tags` join table. Person tags are deliberately absent from the card: delegation is assigned exclusively through the Waiting For routing button's `PersonTagPickerSheet`, whose selection is committed by the routing write that sets intent + person tags atomically. Because context/project edits never touch `todos.intent` or person-tag join rows, the intent ⊥ delegate orthogonality invariant holds structurally — attaching a project tag to a `maybe` task leaves it `maybe`. Unlike the person-tag methods, these edits do not stamp `last_clarified_at`; the clarified moment is bound to the delegate axis, not categorisation.

### FocusModeNotifier (`providers/focus_session_provider.dart`)

A `NotifierProvider<FocusModeNotifier, FocusModeState>` that holds ephemeral focus session state:

- `activeTodoId` — the task currently being focused on.
- `sessionStart` — wall-clock time when the focus segment started.

`elapsed` is derived: `now − sessionStart`. There is no pause state here — the sprint/break rhythm (including its persistence across restarts) is owned entirely by `SprintTimerProvider`.

State is **ephemeral** (in-memory only). The durable record of the active engagement is the open `TimeLog`; for session-backed focus, `FocusSession.currentTaskId` mirrors it. Restoration after a restart re-attaches by reading the active `TimeLog` (`resumeFrom`), which covers session-backed and ad-hoc engagement alike.

Key methods:
- `startFocus(todoId)` — starts an engagement. With an open `FocusSession`, calls `FocusSessionDao.setCurrentTask` (which opens a session-attributed `TimeLog` and sets the Focus pointer — the task need not be on the Plan); with no session, opens an ad-hoc `TimeLog` directly via `TimeLogDao.openLog` (null session FK — engagement is independent of FocusSession, ADR-0005). Then sets `sessionStart`.
- `resumeFrom(todoId, startedAt)` — restores the in-memory state after a restart from the active `TimeLog`'s `started_at`; does not touch DB state.
- `endFocus()` — closes the open `TimeLog` (via `FocusSessionDao.setCurrentTask(null)` when a session is open, `TimeLogDao.closeLog` otherwise), then clears in-memory state.

### FocusSession model (`database/tables.dart`)

`FocusSessions` — one row per planning session. An open session (`ended_at IS NULL`) is the single source of truth for:

- The task currently being focused (`current_task_id`).
- Which tasks are on today's plan (via the `FocusSessionTasks` junction table).

`FocusSessionTasks` (`focus_session_id`, `task_id`, `position`, `disposition`) lists the ordered tasks selected during the planning ritual. The `disposition` column records the user's per-task choice made during session review (see below); `NULL` while the session is open or for done tasks.

Accessed via `FocusSessionDao` (in `database/daos/focus_session_dao.dart`):
- `openSession(userId, taskIds)` — opens a new session with the given task list. Sessions never auto-close (ADR-0020): if one is already open, this **throws `StateError`** — the caller must have the user close it via Evening Shutdown first. This throw is the sole enforcement of the single-open-session invariant (the PowerSync views preclude a schema constraint).
- `watchQualifyingSessionExists(esAnchor)` / `qualifyingSessionExists(esAnchor)` — stream/one-shot for "does a session exist with `started_at >=` the most recent Evening Shutdown anchor" — the ES-anchor day-attribution predicate (ADR-0020).
- `closeSession(sessionId)` — closes the session and any open `TimeLog`.
- `setCurrentTask(sessionId, taskId?)` — atomically closes prior `TimeLog`, opens a new one for `taskId` (if non-null), updates `current_task_id`. The task need not be a Plan member — the Focus may point at any Outcome being engaged (off-Plan engagement, ADR-0005); the TimeLog still attributes to the session and the Plan never auto-grows.
- `watchActiveSession(userId)` / `getActiveSession(userId)` — stream/one-shot for the open session.
- `watchSessionTasks(sessionId)` / `watchSessionTasksForUser(userId)` — ordered task list.
- `setTaskDisposition(sessionId, taskId, disposition)` — writes a single `disposition` value; throws `StateError` if the task is not in the session.
- `reviewAndCloseSession(sessionId, dispositions, now?)` — atomic commit for session review: writes all disposition values, updates `intent = 'maybe'` for each `'maybe'` task, closes open `TimeLog`, closes session.
- `getLastClosedSessionRolloverTaskIds(userId)` — returns `task_id` values with `disposition = 'rollover'` from the most recently closed session.

### FocusSessionReview (`screens/review/`, `providers/focus_session_review_provider.dart`)

The session review screen is shown when the user taps "End Session" on `FocusScreen` and at least one task is unfinished. It lets the user assign a per-task disposition to each pending task before the session is formally closed.

**Dispositions (`models/review_disposition.dart`):**
- `rollover` — pre-select for the next planning session (task keeps `intent = 'next'`).
- `leave` — return to Next Actions without any mutation.
- `maybe` — defer; `reviewAndCloseSession` writes `intent = 'maybe'` to the todo.

**`FocusSessionReviewState`** (managed by `FocusSessionReviewNotifier`):
- `sessionTasks` — all tasks that were part of the session.
- `dispositions` — in-memory `Map<taskId, ReviewDisposition>` for pending tasks.
- `allPendingReviewed` — true when every pending task has a disposition.
- `isSubmitting` — true while the async commit is in flight.

**`FocusSessionReviewNotifier`**:
- `initFromSession(sessionId)` — loads session tasks; called once on screen mount.
- `setDisposition(taskId, disposition)` — updates the in-memory map.
- Review is committed by `EveningShutdownNotifier.closeDay` (`providers/evening_shutdown_provider.dart`), which calls `dao.reviewAndCloseSession` to write dispositions and close the session. There is no completion flag: closing the session is what makes the Now screen's planning-done derivation (an open session exists) and the Evening Shutdown Cadence Trigger stand down (ADR-0020). On close it also best-effort cancels today's pending Evening Shutdown notification (the fire is moot with no open session).

**Routing**: `/focus-session-review` is a top-level `GoRoute` outside the `ShellRoute`, accepting the session ID via `GoRouterState.extra`. The `FocusScreen` "End Session" button navigates here when unfinished tasks exist; if all tasks are done it calls `closeSession` directly and navigates to `/inbox`.

**Rollover pre-population**: `FocusSessionPlanningNotifier.ensureRolloverPreload()` queries `getLastClosedSessionRolloverTaskIds` and prepends any rollover IDs to `pendingSelectedTaskIds`, so carried-over tasks appear pre-selected in the Plan Summary step; the user can deselect them. It is (re)computed on **every** planning entry — the notifier `build()` microtask (cold start), `reEnterPlanning()` (the sequenced Shutdown → Planning replan, awaited before Close Day routes to the screen), and the planning screen's mount post-frame callback (warm-process replan) — because the notifier builds once per process and never rebuilds, so a build-only preload missed every in-process replan path (#461). The method is idempotent and safe to call repeatedly: it is **skipped while a session is open** (`getActiveSession() != null`), so a mid-day cold start does not drag the previous period's already-consumed rollover IDs into a fresh draft; and its merge adds only IDs that are in neither `pendingSelectedTaskIds` nor `reviewedTaskIds`, so a task the user deliberately skipped or deselected is never resurrected (`undoTaskReview`, which clears both lists, does restore the rollover default on the next entry — by design). It writes no dispositions — carrying a task over stays a user decision.

### ActiveFocusScreen (`screens/active_focus_screen.dart`)

A `ConsumerStatefulWidget` with `WidgetsBindingObserver` for lifecycle events:

- **Done**: cancels the sprint, `markDone` → `endFocus()` → snackbar with next task → `context.go('/focus')`.
- **Stop**: cancels the sprint, `endFocus()` → `context.go('/focus')` without completing the task; it returns to the focus list.

### Background Notification

When `AppLifecycleState.paused` fires during an active focus session, `NotificationService.showFocusNotification()` shows an `ongoing` Android notification (low importance, no sound). A `Timer.periodic` updates the notification body every minute. Cancelled on `AppLifecycleState.resumed`.

## Auth Provider Interface

The app supports multiple authentication backends selected at compile time.

### AuthProvider abstract interface

`app/lib/auth/auth_provider_interface.dart` defines:
- `buildLoginWidget(context)` — returns the sign-in widget for that backend.
- `signIn(params)` — performs sign-in; returns `AuthResult`.
- `signOut(refreshToken)` — revokes the server session.
- `restore()` — silently restores a session from secure storage; returns `AuthResult?`.

### AuthResult

`AuthResult` is the canonical return type for every provider sign-in:

```dart
class AuthResult {
  final String accessToken;
  final String refreshToken;
  final String userId;  // decoded from the JWT `sub` claim
}
```

`AuthNotifier` in `providers/auth_provider.dart` only deals with `AuthResult` — it never inspects JWT bytes itself.

### Compile-time mode selection

`app/lib/auth/auth_mode.dart` exposes `authImplProvider` (a Riverpod `Provider<AuthProvider>`).  The active implementation is chosen at build time:

```bash
flutter run --dart-define=JEEVES_AUTH_MODE=sws   # Sign-In With Solana
flutter run                                        # default: email + password
```

| `JEEVES_AUTH_MODE` | Implementation | File |
|---|---|---|
| `password` (default) | `PasswordAuthProvider` | `auth/password/password_auth_provider.dart` |
| `sws` | `SwsAuthProvider` | `auth/sws/sws_auth_provider.dart` |

### Adding a new auth provider

1. Create `app/lib/auth/<name>/<name>_auth_provider.dart` implementing `AuthProvider`.
2. Add a case to the `switch` in `auth_mode.dart`.
3. Pass `--dart-define=JEEVES_AUTH_MODE=<name>` at run time.

## Local Search

Universal search is implemented entirely client-side against the local SQLite store, with no network dependency.

### SearchDao

`lib/database/daos/search_dao.dart` — a plain Dart class (not a `@DriftAccessor`) that exposes a single `search(userId, SearchQuery)` method returning a reactive `Stream<List<SearchResult>>`.

**Query strategy:** A single Drift LEFT OUTER JOIN across `todos`, `todo_tags`, and `tags`. Drift's type-safe `readTable` / `readTableOrNull` API handles all column mapping so no manual SQL parsing is needed. Structured filters (state, energy level, time estimate, due date range) are applied as SQL WHERE clauses. Free-text search and tag-scope filtering are applied in Dart after the join, which avoids FTS5 trigger compatibility issues with PowerSync views.

**Why not FTS5?** In production, `todos` is a PowerSync-managed SQLite view. SQLite only supports `INSTEAD OF` triggers on views, not `AFTER INSERT/UPDATE/DELETE`, so the standard FTS5 content-table + trigger pattern cannot be used. LIKE + Dart-side string matching on 10k rows completes in < 10 ms in practice.

### Search models

- `lib/models/search_query.dart` — plain Dart class holding text, state set, tag-ID set, energy levels, date range, time-estimate cap, and the `includeDone` flag. No code generation required.
- `lib/models/search_result.dart` — wraps a Drift `Todo` + its `List<Tag>` + a `Set<SearchMatchField>` indicating which fields matched + an optional notes snippet.

### Providers

`lib/providers/search_provider.dart`:

- `searchQueryProvider` — `NotifierProvider<SearchQueryNotifier, SearchQuery>` that the search screen writes to on each (debounced) keystroke.
- `searchResultsProvider` — `StreamProvider.autoDispose` that watches `searchQueryProvider` and delegates to `SearchDao.search`, grouping results by `GtdState`.
- `recentSearchesProvider` — `NotifierProvider<RecentSearchesNotifier, List<String>>` backed by `SharedPreferences` (max 10 entries, MRU order).

### Navigation

The search screen lives at `/search` outside the `ShellRoute` (full-screen, no drawer). It is reachable via:
- The **Search** entry in the drawer navigation (visible on every GTD list screen).
- **Ctrl+K** or **/** keyboard shortcuts registered in `AppShell` via Flutter's `Shortcuts` + `Actions` API.

## Synced Preferences

`syncedPreferencesProvider` (`lib/providers/synced_preferences_provider.dart`) is the single source of truth for all user-configurable settings that should survive across devices. It is an `AsyncNotifierProvider<SyncedPreferencesNotifier, SyncedPreferences>` backed by the `user_preferences` Drift table, which PowerSync replicates from PostgreSQL.

### Storage model

All preference values are stored as JSON-encoded TEXT. A NULL value is a tombstone (treated as absent by `get`/`watch`). The `SyncedPreferences` value class provides a typed `get<T>(key)` accessor.

### Conflict resolution

Per-key conflict strategy is defined in `services/user_preferences_conflict.dart` — a `ConflictStrategy` registry (`lww` default, `maxTimestampValue` for snooze floors, `setMerge` provisioned for future list keys) with a pure `resolvePreferenceConflict` function. `strategyForKey` resolves in three steps: an exact entry in `preferenceConflictRegistry` wins, then the `snoozed_until` suffix rule, then the `lww` default. A key may register `lww` explicitly to record that its strategy was chosen rather than inherited (`clarify_mode` does). Deletion is a tombstone (present row, NULL value), never a physical removal. During normal reconciliation a server-absent row keeps the local value; the one residual wipe path is a backend-rejected upload (SYNC.md window 3), prevented by backend idempotency — and if it does happen, the connector dead-letters the entry (payload preserved, sync indicator flags the error, debug builds assert) instead of dropping it silently. The full matrix and the PowerSync reconciliation behaviour live in [SYNC.md](./SYNC.md).

### One-time migration

`_migrateSharedPreferencesIfNeeded` runs on first load when the `user_preferences` table is empty. It reads two groups of keys from `SharedPreferences` and upserts them into the Drift `user_preferences` table. Settings keys are then removed from `SharedPreferences` (Drift is now the authority); ceremony keys are retained in `SharedPreferences` so cold-start init functions can read them before Riverpod loads.

**Settings keys** (cleared from SharedPreferences after migration):

| Key | Type |
|---|---|
| `focus_settings_sprint_duration_minutes` | `int` |
| `focus_settings_break_duration_minutes` | `int` |
| `focus_session_planning_settings_time_hour` | `int` |
| `focus_session_planning_settings_time_minute` | `int` |
| `focus_session_planning_settings_notification_enabled` | `bool` |
| `focus_session_planning_settings_banner_enabled` | `bool` |
| `focus_session_planning_settings_default_snooze_duration` | `int` |

**Ceremony keys** (copied to Drift but retained in SharedPreferences):

| Key | Type |
|---|---|
| `planning_banner_dismissed_date` | `String` (ISO date) |
| `planning_notification_skipped_date` | `String` (ISO date) |
| `planning_notification_snoozed_until` | `String` (ISO datetime) |
| `shutdown_ritual_completed_date` | `String` (ISO date) |
| `shutdown_banner_dismissed_date` | `String` (ISO date) |
| `shutdown_notification_skipped_date` | `String` (ISO date) |
| `shutdown_notification_snoozed_until` | `String` (ISO datetime) |

### Cross-device reactivity

`SyncedPreferencesNotifier.build()` subscribes to `dao.watchAll(userId)`. When PowerSync writes a remote change to the local `user_preferences` table, the stream fires and the in-memory state updates automatically. Providers that derive state from preferences (e.g. `focusSettingsProvider`, `focusSessionPlanningSettingsProvider`, `clarifyModeProvider`) watch `syncedPreferencesProvider` via `ref.listen` and re-derive their state on each change.

## Focus Session Planning State

The focus session planning feature uses Riverpod providers, the `user_preferences` Drift table via `syncedPreferencesProvider` (the cross-device source of truth for settings and ceremony state), and `SharedPreferences` (for cold-start reads before Riverpod loads). "Planning done today" is **not** a stored flag — it is derived from persistent session data (an open `FocusSession` exists, via `activeSessionProvider`), so it survives process death (ADR-0020; the fix for issue #460).

### Key objects

| Object | Type | Purpose |
|---|---|---|
| `activeSessionProvider` | Riverpod `StreamProvider` | The open `FocusSession` or null — the Now screen's planning-done derivation |
| `qualifyingSessionTodayProvider` | Riverpod `StreamProvider` | Whether a session started since the last ES anchor exists — the Daily Planning nudge's day-attribution gate |
| `shutdownThenPlanProvider` | Riverpod `NotifierProvider<bool>` | Carries the and-then-plan intent through the sequenced Shutdown → Planning entry |
| `FocusSessionPlanningNotifier` | Riverpod `NotifierProvider` | Step navigation, task mutations, skip/snooze |
| `FocusSessionPlanningSettingsNotifier` | Riverpod `NotifierProvider` | User preferences: planning time, notification/banner toggles, snooze duration |

`FocusSessionPlanningNotifier` is not auto-disposed, so exiting the ceremony mid-ritual abandons the performance but retains the working state (step, cursors, routings) in memory as a draft that seeds the next performance. A direct "Plan the Day" with no open session resumes that draft (issue #180). The completed-performance reset (`reEnterPlanning()`) now happens on the sequenced Shutdown → Planning path: Re-plan is only offered while a session is open, so it lands on the blocked-start interstitial and passes through Evening Shutdown first; Close Day then routes into planning with a fresh performance. The draft is in-memory only and silently degrades to a fresh start after process death — accepted behaviour (CONTEXT.md § Ceremony); tests must not assert draft survival across restarts.

### Inbox clarification step — snapshot+index navigation

Step 0 (`InboxClarificationStep`) uses a fixed snapshot rather than a live DB stream so the user navigates a stable, ordered list even as the underlying inbox data changes during the session.

**State fields on `FocusSessionPlanningState`:**
- `inboxNav: SnapshotNav<String>` — fixed snapshot of inbox item IDs loaded at step start (oldest-first, respecting the active tag filter), plus the current cursor.
- `inboxRoutings: Map<int, InboxRoutingRecord>` — maps snapshot index → record holding the chosen `RoutingKind`. Drives the "previously selected" affordance on revisit (the step translates to `ProcessAction` for the widget via `RoutingKind.toProcessAction()`).

**`FocusSessionPlanningNotifier` methods:**
- `loadInboxSnapshot()` — idempotent; reads the tag filter at load time, freezes the list oldest-first. Subsequent calls are no-ops.
- `nextInboxItem()` / `previousInboxItem()` — advance or retreat the cursor. `previousInboxItem()` clamps at 0 (method-level); `nextInboxItem()` has no upper-bound clamp itself — the planning screen's Next button gates further progression at `inboxIndex >= inboxSnapshot!.length` (UI-level gating).
- `skipInboxItem(id)` — records no routing; just calls `nextInboxItem()`.
- `recordInboxRoutingAndAdvance(kind)` — state-only. The DAO write is owned by `ProcessToHandlers` (see "Routing transitions" below); this method simply records the chosen `RoutingKind` in `inboxRoutings` for the current index and advances the cursor.
- `processInboxItem(id)` / `processInboxItemToWaitingFor(id)` / `processInboxItemToMaybe(id)` / `processInboxItemToDone(id)` / `processInboxItemToTrash(id)` — older bundled helpers that combine the `ClarificationService.clarifyToOutcome` write and the state update. Retained because the existing test suite drives them directly; production code (`InboxClarificationStep` / `ZeroInboxStep`) uses the widget-owned write path instead.
- `getPersonTagIds(todoId)` — returns person-tag IDs for pre-seeding the person picker on a Waiting For revisit.

The **Next** button in `FocusSessionPlanningScreen` is gated on `nav.isLoaded` — enabled once the snapshot has loaded. `InboxClarificationStep` delegates to `ClarifyStep` (`app/lib/widgets/ceremony/clarify_step.dart`), which handles the loading/empty/completion branching inline. The footer's Skip↔Next-step swap is controlled by `!nav.isComplete`; Skip is shown while items remain (even on the last item), and Next step appears only once the cursor passes the end.

### Routing transitions — single source of truth

Every clarification UI flow writes through `ClarificationService` (`app/lib/services/clarification_service.dart`, exposed via `clarificationServiceProvider`) — the single write path for the flow, per the issue #184 reversibility directive. The interface carries two families of write, both in CONTEXT.md's Capture/Outcome vocabulary:

- **Outcome routing** (review surfaces — re-clarifying an Outcome that already exists) — `clarifyToOutcome`, `completeOutcome`, `completeCurrentAction`, `stampClarified`, `updateFields`, plus the `exists` / `getPersonTagIds` reads the flows need to guard their writes. `DaoClarificationService` delegates these 1:1 to the `TodoDao` / `ActionDao` (and, for the capture-existence read, `CaptureDao`) methods below. Inbox flows do **not** use this family: clarifying a Capture goes through Capture clarification below. `completeCurrentAction` is the odd one out and deliberately so: it is an engagement write that does *not* stamp `last_clarified_at` (ADR-0001 story 4), exposed here because the Focus "Done" flow completes the Action and then takes its re-clarification verdict through the sibling methods on this same interface.
- **Capture clarification** (ADR-0006, the split model) — `clarifyCaptureToOutcome`, `discardCapture`, `captureExists`. `clarifyCaptureToOutcome` is the create-half of clarifying a Capture: in one transaction it inserts a *new* clarified Outcome from the clarify-card draft (via `TodoDao.insertOutcome` + `applyRouting`), attaches the draft's non-person tag ids and any Waiting-For delegate, links the Capture to the Outcome (`CaptureDao.linkOutcome` — provenance), and stamps `captures.clarified_at` (1-1 mode). Re-routing a Capture (Ceremony Back → re-tap) drops the Outcome the earlier tap carved and its link, then recreates, so re-tapping never accumulates a second Outcome. Because Capture↔Outcome is many-to-many, that drop retracts only *this* Capture's claim: each Outcome is unlinked first and deleted **only if no other Capture still links to it** — an Outcome shared via merge survives, merely unlinked, so one Capture's re-route can never destroy another's clarified work. `discardCapture` is the zero-Outcome verdict: it stamps `clarified_at` and creates nothing, applying the same merge-safe cleanup so a Back→Discard leaves no orphan behind and no shared Outcome damaged. Discard never fabricates a Trash Outcome; Trash-the-List stays about Outcomes. Both write methods also re-check the Capture's existence inside their transaction, so a Capture hard-deleted between the callsite pre-check and commit rolls the mutation back rather than minting an orphan Outcome or a dangling link. These are the write path every Capture clarify surface uses: the standalone inbox-clarify screen, the daily-planning inbox step, and the Weekly Review zero-inbox step. `clarifyCaptureToOutcome` rejects `RoutingKind.trash` outright — routing a Capture to Trash is the zero-Outcome discard, so a caller that asks for a trashed Outcome fails loudly rather than leaving a phantom row on the Trash List.
- **n-m clarification** (issue #434) — `carveOutcome`, `mergeIntoOutcome`, `unlinkOutcome`, `completeCaptureClarification`. These split what `clarifyCaptureToOutcome` fuses into one shot, because n-m mode needs the create-link step to be repeatable and the stamp to be the user's own explicit act. `carveOutcome` inserts a new Outcome, attaches the given tag ids and links it — no stamp, no overwrite of an earlier carve. `mergeIntoOutcome` links an existing Outcome (idempotent, merge links and never consumes). `unlinkOutcome` always drops the link, and deletes the Outcome only when the caller passes `deleteCarved` *and* no other Capture still claims it. `completeCaptureClarification` stamps `clarified_at` and touches nothing else, keeping every linked Outcome — the counterpart of `discardCapture`, which is the same stamp plus the merge-safe cleanup. All four re-check row existence inside their transaction for the same reason the 1-1 pair does.

Nothing outside the service may bake "Inbox is just a Todo with `clarified = false`" into a load-bearing assumption. The Capture/Outcome split has landed end to end (ADR-0006, #184): the Inbox reads `captures`, and this seam is what let the UI cutover touch only the service callsites.

`TodoDao.applyRouting(todoId, to:, actionText:, personTagIds:, userId:, now:)` — reached through `ClarificationService.clarifyToOutcome` — is the single source of truth for **routing verdicts**: every route the user picks on a clarify or review surface (inbox-clarify, re-clarification review, or any periodic-review step) lands in this one write. The service's other write methods delegate to their own DAO paths — `completeOutcome` → `TodoDao.markDone`, `stampClarified` → `TodoDao.stampLastClarifiedAt`, `updateFields` → `TodoDao.updateFields` — so `applyRouting` is not the sole mutator of the `clarified` / `intent` / `done_at` columns or of the Outcome's current Action, but it is the only path that applies a `RoutingKind`.

`RoutingKind` (`app/lib/models/todo.dart`) names the destinations: `nextAction`, `waitingFor`, `maybe`, `done`, `trash`. Each value defines the desired final column state (the forward matrix); `applyRouting` writes that state in a single transaction and stamps `last_clarified_at`. Because the matrix is exhaustive, callers do not need a separate revert step before re-applying. The `done` arm also terminates the Outcome's current Action (ADR-0001 story 4, the same cascade `markDone` runs) via `ActionDao.applyCompleteCurrentAction`, which writes nothing to `todos` at all — the cursor is retired (ADR-0022), so there is no cursor left for the Action side to keep agreeing with. `trash` leaves Action rows untouched.

**Orthogonality invariant (intent ⊥ delegate ⊥ user-action):** `applyRouting` writes the *intent* axis. The *delegate* axis (person tags) is mutated only when the caller explicitly passes `personTagIds` — a Next/Someday/Trash route on a delegated task does not strip the delegate, so a task can be `waiting for trixy` *and* have a new next action like `call trixy for update` without losing the delegate when the user routes it. The *user-action* axis (the Outcome's current Action) is written by `applyRouting` only when the caller passes `actionText` (typically through the `nextActionDialog` modifier or a callsite-owned setter); plain Next / Waiting For routes from `ProcessToHandlers` do not synthesise a phrase.

**Cleanup invariant on `done_at`:** any non-Done, non-Trash route clears `done_at` if set, so promoting a previously-completed task back to active state can't leave a stale completion timestamp. `Done` refreshes the timestamp; `Trash` leaves it alone so the completion record survives a soft-delete. The Action side needs no matching cleanup: a `done` Action row stays as history (ADR-0018), and a re-activated Outcome either carries a new phrase — minting a fresh `current` row — or stays Actionless until the user re-clarifies (ADR-0004).

**Restore routes through the same matrix:** the task-detail status sheet restores a trashed Outcome via "Restore to Next" / "Restore to Someday/Maybe", and a done-only Outcome via a single "Restore" (to Next); all three tiles call `TaskDetailNotifier.restoreTo(RoutingKind)` → `applyRouting`. There is no bespoke restore DAO method — the forward matrix already sets the chosen intent, clears `done_at` (cleanup invariant; required so a completed-then-trashed Outcome re-projects onto Next / Someday-Maybe rather than Done), stamps `last_clarified_at`, and leaves person tags alone (orthogonality invariant), so a delegated Outcome restored to Next correctly resurfaces on Waiting For too.

**Provenance — "Captured from…" (issue #184 Phase 4):** `TaskDetailScreen` renders a collapsed section listing the Captures an Outcome was clarified from — each source Capture's raw fragment and when it was captured — driven by `capturesForOutcomeProvider` (`CaptureDao.watchCapturesForOutcome`, the `capture_outcomes` join). The section is hidden entirely when the Outcome has no links, so historical Outcomes (created before the split, or outside the clarify flow) show nothing and no threshold logic is needed. Links are written by `ClarificationService.clarifyCaptureToOutcome`, so every Capture clarified since the cutover carries one; Outcomes that predate it show nothing.

**Live-refresh invariant (view writes must self-notify):** in production `todos` / `tags` / `todo_tags` are PowerSync views with `INSTEAD OF` triggers, so a Drift `UpdateStatement.write` / `DeleteStatement.go` against them reports `changes() == 0` and Drift skips its built-in stream invalidation (which is gated on `rows > 0`). That leaves the async `SqliteAsyncDriftConnection` bridge — `PowerSyncDatabase.updates` → `handleTableUpdates` — as the *only* thing that refreshes view-backed watchers, and that bridge can be briefly silent on a cold start. Every `TodoDao` method that writes the `todos` view directly therefore calls `GtdDatabase.notifyTodosViewWrite(...)` immediately after the write (`applyRouting`, `setCurrentActionText`, `setCurrentActionTextIfActionless` (only on its write path — the skip path notifies nothing), `rescheduleTask`, `stampLastClarifiedAt`, `setPersonTagsAndStamp`, `updateFields`, and the `delete`-based `deleteOutcome`) to give Drift a second, in-process invalidation path, so the `todos`-backed lists — Next Actions, Waiting For, Someday/Maybe and the review surfaces — refresh without an app restart. The Inbox list and its badge are `captures`-backed (`CaptureDao.watchInbox` / `watchInboxCount`) and get the same guarantee from the `notifyCapturesViewWrite` analogue. The helper emits kind-less `TableUpdate`s, so a single call serves updates and deletes alike. Only `update` / `delete` need it: `into(todos).insert(...)` and `customUpdate` / `customInsert` notify unconditionally, so captures and DAO methods built on them (`markDone`, `setIntent`, …) already satisfy the invariant. Any new method that writes a view directly with `update`/`delete` must add the same call. `actions` is a view under the same discipline: `ActionDao` calls `GtdDatabase.notifyActionsViewWrite()` after every write, and the `TodoDao` methods that touch both grains in one transaction (`setCurrentActionText`, `setCurrentActionTextIfActionless`, `applyRouting`, `deleteOutcome`) notify both the `todos` and `actions` views after it commits. `completeCurrentAction` notifies both too, despite writing nothing to `todos` at all — the cursor is retired (ADR-0022), so there is no `todos` write left to gate the notify on. It still fires because the Outcome's own list membership changes when its Action completes, and two list watchers name only `{todoTags, tags}` in `readsFrom`, so an `actions`-only notification would never reach them; the notify rides on `ActionWriteEffect.changed` rather than `stamped`, which is always false for completion.

### `ProcessToHandlers` — the canonical "process to" action bar

`ProcessToHandlers` (`app/lib/widgets/process_to_handlers.dart`) is the single widget rendered wherever the user commits a routing verdict — against either shape of the ADR-0006 split, an Outcome (`OutcomeSubject`) or a Capture (`CaptureSubject`). Its surfaces: the standalone `InboxClarifyScreen`, the inbox-clarify card (planning Step 0 and weekly review's zero-inbox step), the daily planning task-review step, and the weekly review's Waiting For / Next Actions / Someday-Maybe steps.

The widget owns its writes, delegated to `ClarificationService`. Callsites speak `ProcessAction` (`keep`, `reclarify`, `next`, `waitingFor`, `someday`, `done`, `trash`, plus the `nextActionDialog` modifier on `next`) and never see `RoutingKind`. Callsites that hold a `RoutingKind` from a session record translate at the read site via the co-located `RoutingKind.toProcessAction()` extension. `keep` and `reclarify` have no `RoutingKind` equivalent (`keep` stamps `last_clarified_at` only; `reclarify` opens a sub-flow whose result bubbles back as the chosen routing action).

The `nextActionDialog` modifier is **on by default** — promoting a Todo to Next always opens `NextActionDialog` to capture a phrase, so a freshly-promoted task lands on the Next list with a defined action rather than re-surfacing in the daily re-clarification queue. The inbox-clarify card opts out via `except: {nextActionDialog}` because it supplies the phrase through the title-as-action coupling instead; the Next Actions weekly-review step also excepts it (it has no Next button at all).

API:

- `include: Set<ProcessAction>` — surface non-default actions (e.g. `keep`). The `nextActionDialog` modifier is default-on, so it is removed via `except`, not added via `include`.
- `except: Set<ProcessAction>` — hide default actions and the default-on `nextActionDialog` modifier (e.g. the Waiting For step uses `except: {waitingFor}` because the user is already on a waiting item, Keep covers re-confirmation; inbox-clarify uses `except: {nextActionDialog}` to keep Next as a one-tap route).
- `disabled: Set<ProcessAction>` — render disabled-state but still draw the button (parent-owned validation, e.g. inbox card disables routes while the title is empty).
- `labels: Map<ProcessAction, String>` — per-callsite label overrides, applied over the subject-resolved defaults. Use sparingly: the defaults are the canonical vocabulary and the widget exists to collapse the pre-extraction drift.

Labels are resolved from the subject, not fixed per action. `trash` is the one action whose canonical name differs by shape: on an `OutcomeSubject` it is **Trash** (`Intent = trash`, landing the row on the Trash List), on a `CaptureSubject` it is **Discard** — the zero-Outcome verdict creates nothing, so the item never reaches that List and "Trash" would name a destination it never arrives at. Because the resolution lives in the widget, the copy cannot drift between clarify surfaces.

The widget owns the tap handler, so no callsite can catch failures itself — it therefore reports them, behind **two separate error boundaries**:

- A **routing write** that throws is caught and reported as "Operation failed. Please try again."; `onAfterRoute` is not called, so a failed write never advances a cursor or records a routing.
- A throwing **`onAfterRoute` hook** is caught separately and reported as "Saved, but finishing up failed…". The write has already landed by then, so reusing the retry copy would invite the user to redo a route that actually succeeded.
- `lastAction: ProcessAction?` — drives the "previously selected" affordance on the matching button when the user backs up to revisit an item.
- `onAfterRoute: (ProcessAction) -> Future<void>` — fires once after the action settles without error (after `keep` stamps `last_clarified_at`, and after a route commits). Used for callsite-specific bookkeeping (advancing a snapshot cursor, recording the routing for the highlight) and for callsite-owned writes on the user-action axis — e.g. `ClarifyCard` mirrors the live title into the Outcome's current Action here when the user routes to Next/Waiting For from a clarify card (title-as-action coupling). Not called when the user cancels a sub-dialog, and not called when the write throws.

  It does **not** imply a persisted route in every case: saving the `nextActionDialog` with an empty phrase deliberately skips the write (promoting to Next with no phrase would land the item actionless) yet still fires the hook, so the callsite can react — its handler re-reads the Outcome's current Action and sees the unchanged value. Handlers must therefore read state rather than assume a write landed.
- `onProcessingChanged: (bool) -> void` — mirrors the bar's in-flight state out to the callsite, for surfaces that render their own affordances beside it. `ClarifyCard` forwards it to its own host; `InboxClarifyScreen` uses it to shut Skip, the app-bar back arrow, the pinned capture action and its `PopScope` during a write, so the verdict cannot land against a screen the user has already left.

Sub-flows owned by the widget:
- The Waiting For button opens `PersonTagPickerSheet`, which **pops with the chosen person-tag ids** (`null` on cancel) rather than writing them itself. The widget awaits that result and, only once the sheet has closed and the subject is confirmed to still exist, commits intent + delegate in a single routing write — `clarifyToOutcome` replaces the person-tag set atomically on an Outcome, `clarifyCaptureToOutcome` attaches it to the Outcome it mints. Cancelling writes nothing and fires no hook. The current Action is on the orthogonal user-action axis and is left alone.
- The `nextActionDialog` modifier opens `NextActionDialog` (`app/lib/widgets/next_action_dialog.dart`) prefilled with the current Action's text — supplied by the callsite as `OutcomeSubject.currentActionText`, from the snapshot of `actions` it already loaded — and writes the new phrase on save — this is the only widget-internal path that mutates the user-action axis. Because the modifier is default-on, this is the standard Next behaviour everywhere except the callsites that `except` it. The weekly review's Waiting For and Someday/Maybe steps rely on it so a promotion to Next captures a phrase; their `onAfterRoute` reads the phrase back and, if the user saved it blank, stays on the item rather than advancing an actionless task onto the Next list. Promoting a delegated Waiting For item to Next keeps its person tags (intent ⊥ delegate) — `applyRouting` only touches the delegate axis when `personTagIds` is passed.
- The `Re-clarify…` button (surfaced by adding `reclarify` to `include`) pushes `ReclarifyRoute`, the named full-page host for `ClarifyCard.forOutcome`. Routing inside the sub-flow is committed by the inner card's own `ProcessToHandlers`; the result is popped back to the outer widget which bubbles it through `onAfterRoute` for callsite bookkeeping (record routing, advance cursor) — the outer widget never re-writes the route. Backing out of the sub-flow without routing returns no result and is bubbled as `keep`, so the review step advances without recording a routing while keeping any field edits the user already saved (an Outcome's text saves on focus loss; its other attributes save as they change).

### Planning nudges

The ritual is never auto-launched. Users are nudged through two opt-in mechanisms, both governed by the Nudge module's Daily Planning Cadence Trigger (`providers/nudge_triggers.dart`):

1. **Banner** — rendered by the shared Nudge banner surface. The Daily Planning Cadence Trigger fires when now is past today's DPR anchor AND no qualifying session exists (`qualifyingSessionTodayProvider` — none started since the last Evening Shutdown anchor), with content preconditions (something to plan) and the loading deferrals. A stale open session (started before the last ES anchor) does not qualify, so the banner re-arms for it and fires alongside Evening Shutdown, which wins via queue ordering (`ritualsByPriority`); tapping it lands on the blocked-start interstitial. `firingSince` is the later of today's DPR anchor and the last ES anchor, so a morning dismiss does not suppress the fresh post-ES-anchor re-arm. Dismiss/snooze state is persisted by the Nudge module (`nudgeStateProvider`), not a `ValueNotifier`.

2. **Local notification** — scheduled daily at the user's configured planning time via `NotificationService.scheduleRitualReminder(RitualId.dailyPlanning, …)`. Uses `flutter_local_notifications` `zonedSchedule` with `matchDateTimeComponents: time` so the OS re-fires it every day. Notification actions: Open (→ `/focus-session-planning`), Snooze (one-off reschedule), Skip today (cancel until tomorrow). Handled in `_handleNotificationResponse` in `main.dart`. Because the OS cannot evaluate DB state at fire time, transitions reconcile best-effort: opening a session cancels today's pending Daily Planning fire, closing one cancels today's Evening Shutdown fire.

### Persistence

Ceremony state (banner dismissed, notification skip/snooze) is persisted to both `SharedPreferences` (for cold-start reads before Riverpod loads) and the `user_preferences` Drift table (for cross-device sync). Settings (planning time, toggles, snooze duration) are persisted exclusively to `user_preferences` via `syncedPreferencesProvider`. On cold start, `initFocusSessionPlanningNotificationSchedule()` reads planning settings from `SharedPreferences`; if not present, values default to 8:00 AM / enabled until `syncedPreferencesProvider` loads and reschedules with the values from Drift.

### SharedPreferences keys (cold-start only)

| Key | Value | Description |
|---|---|---|
| `planning_banner_dismissed_date` | `yyyy-MM-dd` | Date banner was last dismissed |
| `planning_notification_skipped_date` | `yyyy-MM-dd` | Date user hit "Skip today" |
| `planning_notification_snoozed_until` | ISO-8601 datetime | When the snoozed notification will fire |

## Evening Shutdown Ritual

The shutdown ritual reviews the day's focus session and lets the user assign a per-task disposition to each unfinished task before closing the session.

### EveningShutdownNotifier (`providers/evening_shutdown_provider.dart`)

A `NotifierProvider<EveningShutdownNotifier, EveningShutdownState>` that drives the shutdown ritual UI (steps 0–2: unfinished tasks → completed summary → confirm close).

**State fields on `EveningShutdownState`:**
- `currentStep: int` — 0-indexed step within the ritual.
- `dispositions: Map<String, String>` — maps task ID → disposition string (`'rollover'` | `'leave'` | `'maybe'`). Held in memory until `closeDay()` commits.
- `unfinishedSnapshot: List<Todo>?` — fixed snapshot of unfinished session tasks loaded at step start; `null` until loaded, `[]` if all tasks are done.
- `unfinishedIndex: int` — points at the task currently being resolved.

**Snapshot+index navigation** (same pattern as the inbox clarification step):
- `loadUnfinishedSnapshot()` — idempotent; reads `watchActiveSessionTasks().first`, filters `doneAt == null`, freezes the list. Subsequent calls are no-ops.
- `nextUnfinishedTask()` — increments `unfinishedIndex`. If the new index would reach `snapshot.length`, calls `advanceStep()` instead so the ritual proceeds automatically.
- `previousUnfinishedTask()` — decrements index (clamped at 0) and removes the in-memory disposition for the returned-to task so the user can re-choose.
- `rolloverTask(id)` / `returnToNextActions(id)` / `deferTask(id)` — each calls `_setDisposition` then `nextUnfinishedTask()`.

**Lifecycle:**
- `closeDay()` — atomically commits all accumulated dispositions via `FocusSessionDao.reviewAndCloseSession`, persists the completion date to `SharedPreferences`, flips `shutdownCompletionNotifier.value = true`, and resets state.
- `dismissBannerForToday()` / `skipShutdownToday()` / `snoozeShutdownNotification(minutes)` — banner and notification suppression helpers.

**Stream providers** driven by the active focus session:
- `completedTodayProvider` — tasks in the active session with `doneAt != null`.
- `unfinishedSelectedTodayProvider` — tasks in the active session with `doneAt == null` that have no in-memory disposition yet; used by the banner and other out-of-ritual consumers to show the remaining count.

## Weekly Review Wizard

A 5-screen ceremony surfaced when the cadence has elapsed (`now − periodic_review_last_completed_at >= 7 days`, or never completed). Internally namespaced `periodic_review`; user-visible copy reads "Weekly Review". The cadence is hardcoded at 7 days.

There is no dedicated brain-dump step in the wizard: capture happens through the inbox (share-sheet, voice, manual entry) throughout the week, so the review only needs to *clarify* the inbox, not re-elicit it.

### State (`providers/periodic_review_provider.dart`)

`PeriodicReviewNotifier` is a `NotifierProvider<PeriodicReviewNotifier, PeriodicReviewState>` whose state is transient — wiped by `completeReview()`. The provider is not auto-disposed, so navigating away mid-ceremony and back resumes the same wizard; only finishing the review clears the in-session snapshots and cursors.

**State fields** (each list-driven step uses the shared `SnapshotNav<T>` primitive from `utils/snapshot_nav.dart`):
- `currentStep: int` — 0..4.
- `inboxNav: SnapshotNav<String>` — todo IDs from the inbox.
- `waitingForNav: SnapshotNav<Todo>` — person-tagged next actions.
- `nextActionsNav: SnapshotNav<Todo>` — active next actions, excluding those that carry a person tag (those are handled by Waiting For).
- `somedayNav: SnapshotNav<Todo>` — `intent = 'maybe'` tasks.

**Disjointness invariant:** each task surfaces in at most one wizard step. The selectors are pairwise disjoint by construction — Inbox vs everything is split by table (Captures vs Outcomes); Waiting For vs Someday and Next Actions vs Someday split on `intent`; Waiting For vs Next Actions split on whether the task carries any person-typed tag (`getNextExcludingPersonTagged` enforces the exclusion in SQL). A future dedicated Projects step will need to re-establish this matrix (project-tagged ⊂ next-actions, so it would have to be ordered ahead of Next Actions or the Next Actions snapshot would have to also exclude project-tagged items).

**Snapshot loaders** are called by `_onStepEnter` each time a step is entered. All four snapshots are also pre-loaded in `loadAllSnapshots()` which runs on ceremony mount, so items routed in an earlier step do not surface in a later one. Empty steps show an empty-state view inline; the user clicks Next to advance rather than being auto-skipped past the step.

**`completeReview()`** writes the completion timestamp to synced preferences via `PeriodicReviewSettingsNotifier`, then resets the in-session state to its initial form so the next entry starts on a clean Step 0.

### Settings (`providers/periodic_review_settings_provider.dart`)

Durable state lives in `user_preferences` under the `periodic_review_*` keys; no new tables. Cross-device LWW + tombstone semantics from `syncedPreferencesProvider` ensure all devices suppress the banner on their next sync after completion. Notification skip/snooze additionally dual-write to `SharedPreferences` for cold-start reads before Riverpod loads — same pattern as the focus-session planning ceremony — so a notification suppression survives a restart even before the synced-prefs stream re-emits. The dual-write happens inside `persistPeriodicReviewSkipToday` / `persistPeriodicReviewSnoozedUntil`; `loadPeriodicReviewNotificationSuppression` reads the SharedPreferences side at startup.

| Key | Type | Purpose |
|---|---|---|
| `periodic_review_last_completed_at` | ISO-8601 datetime | Drives `isDue` |
| `periodic_review_banner_dismissed_date` | `yyyy-MM-dd` | Suppresses banner today |
| `periodic_review_banner_enabled` | `bool` (default `true`) | Banner toggle |
| `periodic_review_notification_enabled` | `bool` (default `true`) | Notification toggle |
| `periodic_review_notification_hour` | `int` (default `9`) | Reminder hour |
| `periodic_review_notification_minute` | `int` (default `0`) | Reminder minute |
| `periodic_review_notification_skipped_date` | `yyyy-MM-dd` | Suppresses today's reminder (dual-written to SharedPreferences) |
| `periodic_review_notification_snoozed_until` | ISO-8601 datetime | One-off snooze fire time (dual-written to SharedPreferences) |
| `periodic_review_nudge_content_firing_edge` | ISO-8601 datetime | Most recent content-state `false→true` firing edge; a content-state dismiss releases once `dismissed_at` precedes it |

Derived providers: `periodicReviewIsDueProvider`, `periodicReviewBannerDismissedTodayProvider`, `periodicReviewBannerEnabledProvider`, `periodicReviewLastCompletedProvider`.

### UI

- `screens/periodic_review/periodic_review_screen.dart` composes four list-driven steps against the shared `Wizard` widget; the "Review Complete" summary screen is rendered standalone once `currentStep` is past the last list-driven step, not as a wizard step. Step transitions go through `advanceStep` / `goToStep`, which fire the entry hook for snapshot loading.
- Each list-driven step's footer is a `ListItemFooter` widget owned by the step (shipped alongside `Wizard` in `app/lib/widgets/ceremony/wizard.dart`). Skip advances the per-item cursor (`advanceInbox` / `advanceWaitingFor` / …) while items remain — including on the last real item; Next step crosses into the following wizard step only after the cursor has advanced past the last item (`nav.isComplete`) and the step body shows its completion placeholder. Back symmetrically retreats the cursor before crossing back; from item 0 of any non-first list-driven step it falls through to `goToStep(currentStep - 1)`. Empty steps show an empty-state view inline; the user clicks Next to advance rather than being auto-skipped past the step.
- Per-item steps (Waiting For, Next Actions, Someday/Maybe) share `_review_card.dart` (`ReviewItemCard`, `ReviewLoadError`, `ReviewEmptyState`). Each per-item step inlines its load-error/loading/empty/completion branching directly in its `build` method (`ReviewLoadError` → spinner → `ReviewEmptyState` → `ReviewItemCard`). Each per-item step's `ProcessToHandlers` includes `ProcessAction.reclarify`, surfacing a `Re-clarify…` button that opens `ReclarifyRoute` — the full `ClarifyCard` UI — as a sub-flow; routing inside the sub-flow is recorded and advances the cursor exactly like a direct tap, while backing out without routing maps to `keep` (advance without recording).
- Step 0 (Process Inbox) uses `ClarifyStep` (`app/lib/widgets/ceremony/clarify_step.dart`) — the same class as DPR's inbox step; it passes WR-specific nav, routings, and callbacks as constructor arguments. The completion frame is the canonical `_InboxCleared` widget shared with DPR.
- `widgets/periodic_review_banner.dart` — teal banner above app-shell views. Banner toggle must be enabled, the user must have at least one todo, and dismissed-today must be false. Given those, it shows when **either** the review is due per the 7-day cadence, **or** the inbox and next-actions are both empty while waiting-for or someday/maybe still holds items. The second trigger fills the gap left by `FocusSessionPlanningBanner` (which suppresses itself in that state per #258) so the user is nudged toward the weekly review when there is nothing to plan today but deferred inventory remains. Both branches read the unfiltered list providers (`unfilteredInboxProvider`, `unfilteredNextActionsProvider`, `unfilteredWaitingForProvider`, `unfilteredMaybeProvider`) so an active context-tag filter does not change visibility.

### Notifications

`NotificationService.schedulePeriodicReviewReminder(time:)` schedules a recurring daily reminder at the configured time using `matchDateTimeComponents: time`. `_rescheduleNotification` only arms that schedule while the review is actually due (`periodicReviewIsDueProvider == true`); on completion the reschedule is triggered by the prefs listener and the schedule is canceled, so the user is not nagged daily until the cadence has elapsed again. Re-arm happens via the same listener on the next prefs write (or via `build()` the next time the notifier is constructed at app launch).

### Trigger reactivity

Nudge Triggers re-evaluate when their predicate's inputs change, not only on an unrelated rebuild, so a Nudge surfaces at its boundary or content edge rather than waiting. Time-based predicates read the shared `clockProvider` (`lib/providers/clock_provider.dart`) and arm timers to their next boundary: the Nudge module's `nudgeBoundaryTickProvider` schedules one timer to the next day-rollover / Evening Shutdown anchor and re-evaluates the Triggers there, while `periodicReviewIsDueProvider` schedules its own timer to the cadence-due instant (`last + 7d`); both cancel via `ref.onDispose`.

The Weekly Review's **content-state Trigger** (inbox and next-actions empty while waiting-for or someday/maybe still holds items) tracks its own firing edge, so a dismiss releases on the next genuine `false→true` content transition rather than at the day boundary. `wrContentFiringProvider` exposes the predicate as a tri-state `bool?` (`null` while the underlying lists load, then `false` / `true`); `contentFiringEdgeProvider` (a `Notifier<DateTime?>`) watches it and, on a `false→true` transition, stamps `clockProvider()` as the new edge and persists it to `periodic_review_nudge_content_firing_edge`. On startup the transition is `null→true`, so it instead restores the persisted edge — or falls back to start-of-today when nothing is persisted — and a cold start mid-firing therefore does not reset an outstanding dismiss. The Nudge dismiss predicate releases when `dismissed_at` precedes the edge (see `CONTEXT.md` → Nudge).

Notification actions: Open (→ `/periodic-review`), Snooze (one-off reschedule via `snoozePeriodicReviewReminder(minutes)`), Skip today (cancels only the snooze id via `skipTodayPeriodicReviewReminder()` so tomorrow's recurring reminder still fires).

## Sprint Timer (Pomodoro Engine)

Focus Mode includes an optional Pomodoro sprint timer bound to the active task. It is not a separate mode — it lives inside the Active Focus Screen as a carousel page revealed by swiping the notes view left. Sprint and break durations are user-configurable (default 20/3 min). The timer persists across app backgrounding via SharedPreferences and fires a local notification at expiry.

### Settings

`lib/models/focus_settings.dart` — `FocusSettings` value type with `sprintDurationMinutes` (default 20) and `breakDurationMinutes` (default 3).

`lib/providers/focus_settings_provider.dart` — `FocusSettingsNotifier` persists values to the `user_preferences` Drift table via `syncedPreferencesProvider` under `focus_settings_sprint_duration_minutes` and `focus_settings_break_duration_minutes`. It re-derives state from `syncedPreferencesProvider` whenever preferences change (including cross-device sync). Exposed in Settings → **FOCUS MODE**.

### State machine

`lib/providers/sprint_timer_provider.dart` — `SprintTimerNotifier` (a Riverpod `NotifierProvider<SprintTimerNotifier, SprintTimerState>`).

**Phases:**

| Phase | Duration | Description |
|---|---|---|
| `idle` | — | No sprint running |
| `focus` | configurable (default 20 min) | Active sprint, countdown running |
| `break_` | configurable (default 3 min) | Break between sprints |

**Key operations:**

- `startSprint(Todo)` — reads `focusSettingsProvider` for durations, then starts a focus sprint; triggers haptic feedback and schedules a local notification.
- `pauseSprint()` / `resumeSprint()` — freezes/resumes the remaining duration; cancels/reschedules the end notification.
- `completeSprint()` — starts the break timer. It does not write time anywhere: time tracking flows through `time_logs` rows, opened and closed by `FocusSessionDao.setCurrentTask` as focus switches (see Time tracking below).
- `stopSprint()` — cancels the timer and clears all persisted state.
- `skipBreak()` — ends the break early and records `lastBreakEndedAt`.

All mutating methods are guarded by `isProcessing: bool` to prevent rapid-tap race conditions.

### Post-break cooldown

`SprintTimerState.isPostBreakCooldown` returns `true` for `breakDurationMinutes` after a break ends (based on `lastBreakEndedAt`). While active, the Jeeves elapsed-time banner suppresses "perhaps take a break" suggestions.

### Persistence across backgrounding

When a sprint starts the notifier stores the absolute end time in `SharedPreferences`. On app resume, `_restoreFromPrefs()` reads the stored end time and recalculates the remaining duration. If the timer has already expired, the expired handler runs immediately (starts the break, or resets to idle — it writes no time; see Time tracking).

**SharedPreferences keys:**

| Key | Type | Description |
|---|---|---|
| `sprint_active_task_id` | String | ID of the task being sprinted |
| `sprint_active_task_title` | String | Cached task title for restore |
| `sprint_end_time` | ISO-8601 datetime | Absolute end time of the current timer |
| `sprint_phase` | `'focus'` \| `'break'` | Current phase |
| `sprint_sprint_number` | int | 1-indexed sprint number |
| `sprint_total_sprints` | int | Total sprints for the task |
| `sprint_is_paused` | bool | Whether the timer is paused |
| `sprint_remaining_seconds` | int | Seconds remaining when paused |
| `sprint_last_break_ended_at` | ISO-8601 datetime | When the last break ended (for cooldown) |

### Notifications

Two stable notification IDs are reserved in `NotificationService`:

- `_kSprintEndNotificationId = 2` — fires when the focus sprint expires.
- `_kBreakEndNotificationId = 3` — fires when the break expires.

Both use `AndroidScheduleMode.exactAllowWhileIdle` (one-shot, not repeating), with a runtime fallback to `inexact` if `canScheduleExactNotifications()` returns false.

### Sprint count

Sprint count for a task is derived from its `timeEstimate` and the configured `sprintDurationMinutes`:

```text
totalSprints = max(1, ceil(timeEstimate / sprintDurationMinutes))
currentSprint = floor(totalMinutesForTask / sprintDurationMinutes) + 1
```

where `totalMinutesForTask` is the live TimeLog-derived total (`TimeLogDao.totalMinutesForTask`).

### Time tracking

`time_logs` rows are the source of truth for time spent: one row per contiguous focus stint on a task, opened and closed by `FocusSessionDao.setCurrentTask` as focus switches. The sprint timer never writes time — a sprint is a display loop layered on top of the running log.

**Action-grain attribution (ADR-0001 story 6, issue #476).** Each `time_logs` row also carries a nullable `action_id` recording *which Action* was being engaged, alongside the `task_id` (Outcome-grain) attribution that stays on every row. The two write sites — `TimeLogDao.openLog` (ad-hoc) and `FocusSessionDao.setCurrentTask` (session-backed) — resolve the Outcome's `current` Action *inside their own transaction* (the blessed `ActionDao.winnerFirstOrderSql` winner rule), so a `planned` or terminated Action can never be attributed by construction, and a concurrent supersede cannot mis-attribute. `action_id IS NULL` means "no Action attribution available": a pre-Action-era log (there is no backfill — which Action was current for a historical stint is unreconstructable), a defensive Actionless edge where the Outcome had no `current` Action at open time, or a log whose Action was later deleted — the FK is `ON DELETE SET NULL` (Alembic 0029; mirrored by `KeyAction.setNull` on the Drift column), so deleting an Action detaches its logs rather than cascade-deleting the time data or blocking the delete. Totals are unaffected either way because they aggregate by `task_id`.

**Terminal-transition hook.** When an Action reaches a terminal state with an open log attributed to it, `ActionDao` closes that log at the transition timestamp: `applyCompleteCurrentAction` (Done) and `applySupersedeCurrentAction` (supersede/clear) both close it. A supersede *with a replacement* also **reopens** a continuation log against the successor Action (copying `task_id`, `user_id`, and `focus_session_id`, `started_at = ts`), so switching Actions closes the current TimeLog and opens a new one with zero seconds lost (CONTEXT.md § Switching Actions). `applySupersedeAndPromote` — the planned-queue "Replace current action" gesture — is the same transition and reopens the continuation against the promoted planned row. An in-place text/metadata edit keeps the same Action id, so the open log is untouched. Done closes at the Action's completion rather than at a later `endFocus()` — deliberate: engagement on a finished Action ends at Done. Because `time_logs` is a PowerSync view in production, every path that closes or reopens a log fires `notifyTimeLogsViewWrite` after commit (gated on `ActionWriteEffect.logChanged`) so the active-log and time-spent watchers refresh without relying solely on the async sync bridge (ADR-0010).

Every surface that shows time-spent derives it from `SUM(time_logs)` at read time, via `TimeLogDao.totalMinutesForTask` (single task, e.g. sprint number) or the correlated subquery `TimeLogDao.totalMinutesSubquery` embedded in list queries (e.g. `FocusSessionDao.watchActiveSessionReviewSurface`, which feeds the evening shutdown's time figures). Per-interval minutes are ceiling-rounded; open rows count up to the current time. These totals remain **task-grain** — they aggregate by `task_id` and so count legacy (`action_id IS NULL`) and Action-attributed rows identically. Per-Action time-spent reads exist alongside them for history: `TimeLogDao.totalMinutesSubqueryForAction` (story 8, issue #478) aggregates by `action_id` instead, and is what `ActionDao.watchTerminatedActions` / `getTerminatedActions` join in per terminated row (see the `actions` data-model note above).

The `todos.time_spent_minutes` column is a dead denormalized cache: nothing writes it since the `transitionState` recompute was retired with PR I. No query may project it as a time-spent source — queries that surface time-spent (`watchActiveSessionReviewSurface`, `getReviewSurface`, `watchPersonTaggedGrouped`) hydrate the model field from the derived subquery instead. Todo rows hydrated by generic `select(todos)` queries still carry the raw (stale) column value in `Todo.timeSpentMinutes`; no UI may display it from those rows. The column is retired: retained in the schema and unread. It has not been dropped — unlike `next_action_text` (ADR-0024) its values are not duplicated anywhere, and a drop would need its own case (it rides #556 with the PowerSync removal).

It is written in exactly one place, and only because it is declared NOT NULL: the op-log projector supplies its declared default when it **creates** a row, so a projected Outcome can be read back at all. Unsynced is not the same as unwritten — the column never travels on the wire, is never a merge input, and the projector's update path leaves whatever a local row holds. See `CollectionCodec.unsyncedInsertDefaults` and [ADR-0030](./adr/0030-merge-strategies-must-be-join-semilattices.md).

### Batching suggestion

`findBatchingCandidates(List<Todo>, {int sprintMinutes = 20})` scans today's tasks for micro-tasks (estimate ≤ 15 min) and greedily selects the largest subset (sorted by estimate ascending) whose combined total fits within one sprint. If 2 or more such tasks are found, Focus Mode shows a dismissible suggestion banner. The caller passes the current `sprintDurationMinutes` from `focusSettingsProvider`.

### UI

- `lib/widgets/sprint_timer_widget.dart` — full carousel page with an idle view ("Start Sprint" button) and an active view (progress ring, MM:SS countdown, phase badge, sprint-dot indicator, playback controls).
- `lib/screens/active_focus_screen.dart` — `PageView` carousel: page 0 = notes (markdown with checkbox support), page 1 = `SprintTimerWidget`. A `_PageDots` indicator sits below the page view. Swipe left from notes to reach the sprint timer.
- `lib/screens/focus_screen.dart` — task list only; no sprint controls. Sprint count badges on task rows use `focusSettingsProvider.sprintDurationMinutes`.

## Task Domain Model

A task's lifecycle decomposes along orthogonal axes — each axis is a separate column or relation, and they combine freely. There is no `state` field; each list view is a SQL filter on these columns.

| Axis | Column / relation | Semantics |
|---|---|---|
| Clarified | `todos.clarified` (bool) | Legacy of the Capture/Outcome conflation. No longer read — the Inbox is `captures.clarified_at IS NULL` — but still written when an Outcome is created. Dropped a release train after #184. |
| Intent | `todos.intent` (`next` \| `maybe` \| `trash`) | What the user wants to do with this task |
| Completion | `todos.done_at` (timestamp, nullable) | Non-null = done; value = when |
| Schedule | `todos.due_date` (date, nullable) | Specific calendar date |
| Current Action | `actions` row with `role = 'current'` | The Outcome's current Action; its existence makes the Outcome **engageable** — there is a concrete thing to do, and only a `current` Action is engageable (CONTEXT.md § GTD Core / Relationships) — its `text` is the phrase. The `todos.next_action_text` cursor it replaced no longer exists (ADR-0001 stories 3 and 9; ADR-0022, ADR-0024) |
| PersonBlocker | `todo_tags` rows referencing a `Tag` with `type = 'person'` | Outcome is blocked on a Person; existence of the link is the block, removal is its resolution |
| Active focus | `focus_sessions.current_task_id` | Which task is currently in progress |
| Today's plan | `focus_session_tasks` rows | Membership in the open session |

A task is **actionable** when:

```text
clarified = true ∧ done_at IS NULL ∧ intent = 'next'
```

**Actionable ≠ engageable, and neither one alone decides Next membership.**
Actionable is the axis combination above — it says nothing about Actions. Engageable is the current-Action axis: the Outcome has a phrase the user can start on. An actionable but Actionless Outcome is still real work the user should see; it drops off Next only when it is *also* PersonBlocked (see the Next List rule below), because that combination is a pure wait.

PersonBlocker is the only Blocker shape modelled today; the remaining shapes from the polymorphic-blockers design (Task / Time / Location) are tracked in TMaYaD/Jeeves#181 and are not part of this model yet.

### Next List

The Next List rule is:

```text
Next = intent='next' ∧ clarified ∧ done_at IS NULL ∧
       (has a current Action ∨ no PersonBlocker on the Outcome)
```

`TodoDao.watchNext(tagIds:)` enforces it, reading "has a current Action" from the `actions` table (ADR-0001 story 3) — the List still *contains* Outcomes; only the predicate's evidence source is the Action entity. The single excluded quadrant is **actionless** (no `current` Action row) **AND** PersonBlocked (carries any `Tag(type='person')`) — that combination is a pure wait and surfaces only on Waiting For. An Outcome with a current Action belongs on Next regardless of any PersonBlocker: `"call Trixy for a follow up"` is doable and eligible for engagement; it also surfaces under Waiting For (the grouping by Person). The overlap between Next and Waiting For is by design — see CONTEXT.md § Next / Waiting For.

The exclusion clause in SQL:

```sql
AND (
  EXISTS (
    SELECT 1 FROM actions
    WHERE actions.outcome_id = todos.id AND actions.role = 'current'
  )
  OR NOT EXISTS (
    SELECT 1 FROM todo_tags tt
    JOIN tags tg ON tg.id = tt.tag_id
    WHERE tt.todo_id = todos.id AND tg.type = 'person'
  )
)
```

The clause applies under context-tag filtering too — the actionable+PersonBlocked overlap stays on filtered Next, the actionless+PersonBlocked Outcome never leaks in.

The Weekly Review wizard's Next-step snapshot (`TodoDao.getNextExcludingPersonTagged`) and the daily re-clarification's "actionless" branch (`TodoDao.getNeedsReview`) apply a stricter per-step person-tag exclusion to keep their own wizard steps disjoint from Waiting For's step. Those are wizard-internal disjointness rules, not the everyday Next List membership rule.

### Waiting For list

The Waiting For list is the implicit grouping of actionable Outcomes that carry at least one `Tag(type='person')` link, grouped by the blocking Person. The List is a SQL projection — there is no `waiting_for` column and no membership table. An Outcome appears under each Person it is blocked on; an Outcome with two PersonBlockers appears twice in the grouped view, once under each Person.

The predicate that selects a row into the list is:

```sql
SELECT DISTINCT todos.*
FROM todos
JOIN todo_tags tt ON tt.todo_id = todos.id
JOIN tags tg     ON tg.id      = tt.tag_id AND tg.type = 'person'
WHERE todos.clarified = 1
  AND todos.done_at IS NULL
  AND todos.intent   = 'next'
```

`TodoDao.watchPersonTagged()` returns the flat list and `TodoDao.watchPersonTaggedGrouped()` returns it bucketed by `Tag`. Adding or removing a PersonBlocker is a Tag-link mutation on `todo_tags` — the same junction table that backs Areas, Labels, and Contexts — and stamps `last_clarified_at` on the Outcome because PersonBlocker is conceptually Clarification (it is a Blocker on the Outcome, not a categorisation), even though the storage shape looks like a Tag link.

**Waiting For overlaps with Next when the Outcome has a current Action.** An Outcome with `intent='next'`, a `current` Action row, and at least one `Tag(type='person')` appears on both lists — Next because the Action is doable (`"call Trixy for a follow up"`), Waiting For because the PersonBlocker is real. An *actionless* PersonBlocked Outcome appears on Waiting For only — the Next predicate (above) excludes that single quadrant.

### Intent semantics

- `next` — normal actionable item; appears on Next (subject to the actionless+PersonBlocked exclusion above) and **also** under Waiting For (grouped by Person) when the Outcome carries any `Tag(type='person')`. The two views overlap by design when both predicates apply.
- `maybe` — deferred for later consideration; surfaces in the Maybe view; excluded from Next Actions and planning reviews.
- `trash` — discarded (soft delete; column domain enforced at DB level). Surfaces on the Trash record screen (see "Record surfaces" under Navigation); restorable to Next or Someday/Maybe from the task-detail status sheet. Rows are never physically deleted.

`TodoDao.setIntent(todoId, userId, intent)` writes the column. `deferTaskToMaybe` is the canonical "defer" verb.

### Internal vs UI terminology

Code names planning and review steps **session-relative** (`focus_session_planning`, `focus_session_review`), not date-relative. UI copy retains user-facing "today" / "this week" language. The split is deliberate: dates belong in copy and timezone-aware UI logic, not in entity names. `FocusSession.started_at` / `ended_at` own session lifecycle; "today" is a derived UI concept.

| Internal identifier | User-visible copy |
| :--- | :--- |
| `focus_session_planning` | "Daily Planning" |
| `focus_session` | "Focus" / "Session" |
| `evening_shutdown` | "Evening Shutdown" |
| `periodic_review` | "Weekly Review" |

The `periodic_review` namespace covers route (`/periodic-review`), provider class names, all `user_preferences` keys (`periodic_review_last_completed_at`, `periodic_review_banner_*`, `periodic_review_notification_*`), and notification action identifiers. No `weekly_review` identifier exists in code; no `periodic_review` string appears in user-visible text. The cadence is hardcoded at 7 days.

## Navigation & Global Filter State

### Record surfaces (Done / Trash)

`/done` and `/trash` are `ShellRoute` children rendering thin `GtdListScreen` wrappers (`DoneScreen`, `TrashScreen`) over the unfiltered `doneProvider` / `trashProvider` streams (`TodoDao.watchDone()` / `watchTrash()`). They are reached from a de-emphasised record group at the bottom of the drawer's scrollable nav column, above the fixed Settings tile — muted styling, no count badges (record size is not actionable signal). Trash lists every `intent='trash'` row regardless of `done_at`, newest-trashed first (`ORDER BY COALESCE(last_clarified_at, updated_at, created_at) DESC` — every trashing write path stamps `last_clarified_at`, so the stamp proxies a dedicated `trashed_at` column; the fallbacks cover legacy rows predating it). Done excludes trashed rows (#278), keeping the two surfaces disjoint. Rows navigate to `/task/:id`; restore lives in the task-detail status sheet (see "Routing transitions"). There is deliberately no purge action — rows are never physically deleted.

### Tag Cloud Navigation Filter

A sticky, multi-select context-tag filter lives in the navigation drawer and persists across screen navigation for the duration of the app session.

**State:** `TagFilterNotifier` (a `Notifier<Set<String>>` in `app/lib/providers/tag_filter_provider.dart`) holds the active set of context tag IDs.  Calling `toggle(id)` adds or removes a tag; `clear()` resets the set.  The `tagFilterProvider` is app-scoped so the state survives route changes.

**Drawer widget:** `TagCloud` (`app/lib/screens/common/tag_cloud.dart`) renders a `Wrap` of `FilterChip`s sourced from `contextTagsWithCountProvider`.  Chip visual weight (font size and opacity) scales linearly with each tag's active-task count relative to the maximum in the set.  Tags with zero active tasks are hidden unless currently selected.  Long-pressing a chip opens `TagManagementSheet` for rename/recolour/merge.

**Active filter indicator:** `_ActiveFilterBar` (embedded in `GtdListScreen`) and `_InboxFilterBar` (embedded in `InboxScreen`) show the currently selected tags as removable `InputChip`s plus a "Clear all" button.  The CONTEXTS section header in the drawer gains a count badge when any filter is active.  `GtdListScreen` takes `showFilterBar: false` for the Done and Trash record surfaces, whose streams deliberately ignore the context-tag filter — rendering a filter bar the list doesn't apply would lie to the user.

**DAO layer:** `TagDao.watchTagsWithActiveCount(userId, type)` uses a `customSelect` SQL query with `readsFrom: {tags, todoTags, todos}` so the count stream re-emits reactively when any of the three tables change.  Each GTD watch method in `TodoDao`, plus `CaptureDao.watchInbox` (the Inbox tag-hint filter), accepts an optional `Set<String> tagIds` parameter; when non-empty a SQL subquery enforces AND semantics: `COUNT(DISTINCT tag_id) WHERE tag_id IN (...) = N`.

**Provider wiring:** Every GTD list provider (`nextActionsProvider`, `waitingForProvider`, `maybeProvider`, `inboxItemsProvider`) watches `tagFilterProvider` and passes the current tag set to its DAO method.  When the filter changes, Riverpod automatically cancels and re-subscribes the DAO stream, so the list view re-renders without any additional work in the UI layer.
