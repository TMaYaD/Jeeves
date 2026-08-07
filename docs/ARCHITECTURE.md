# Architecture

<!-- This document describes the current state of the system. Rewrite sections when they become inaccurate. Do not append change logs. -->

This document describes the architectural design of Jeeves, a productivity-focused todos application.

## High-Level System Overview

The system follows an offline-first architecture, allowing clients to work securely and seamlessly without an internet connection, while continuously syncing with the central database when online.

- **Frontend Clients:** Flutter-based applications supporting mobile (iOS/Android), web, and desktop.
- **Backend Service:** A Python-based FastAPI service — the Minimal Sync Server (ADR-0026). It authenticates Devices and serves the op log; it owns no domain schema, no domain routes and no AI endpoints.
- **Sync Engine:** the minimal sync server's content-blind op log — signed ops over per-Workspace logs, replicated device to device (ADR-0026). It is the only sync path on the device.
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
- **Local Storage:** Offline-first, two Drift-owned SQLite files per device, each opened through its own adapter (`sqlite3_flutter_libs` underneath both) — `jeeves_domain.sqlite`, the domain read model, over `sqlite_async` / `drift_sqlite_async`; and `jeeves_sync.sqlite`, the op log, over Drift's native executor on a background isolate (`NativeDatabase.createInBackground`), so reducing a page of ops never competes with the UI isolate for frames. See [§ Two stores](#two-stores-and-the-path-between-them), [§ Current adapters](#current-adapters) and [ADR-0035](./adr/0035-domain-store-cut-over-by-fresh-file.md).
- **API Communication:** `dio` and `retrofit`.
- **Data Models:** `freezed` and `json_serializable` for robust immutable models.
- **Sync:** the minimal sync server's op log — signed ops over per-Workspace logs, authored from enrolment onward and replicated device to device ([§ Minimal Sync Server](#minimal-sync-server), ADR-0026, ADR-0034).
- **Web storage:** none. Both store adapters stub out on web and throw (see [§ Platform I/O Adapters](#platform-io-adapters)); a web build compiles, which is the bar. The fleet is one Android phone.

### Backend (Python/FastAPI)

Located in `backend/`.

- **Framework:** `fastapi` with Python 3.12+ running on `uvicorn`.
- **Database ORM:** `sqlalchemy` (with `asyncpg` for async I/O) and `alembic` for migrations.
- **Validation:** `pydantic`.
- **Redis:** `redis` — auth nonce and rate-limit counters, recovery-escrow and member-auth state. Not a task-queue broker; there are no background workers.
- **Scope:** the Minimal Sync Server and nothing else (ADR-0026). `app/auth`, `app/sync`, `app/health` — no domain schema, no domain routes, no AI endpoints. #556 dropped the mirrored tables and the REST surface over them; the client is the source of truth and the server never interprets an envelope's contents.
- **Deployment:** one Dokku app. Backend CD pushes it and the `Procfile`'s release phase runs Alembic; there is no second service and no sync-rules publish step. #556 removed the replication deployment — the `journeyapps/powersync-service` app, `infra/powersync/sync-config.yaml`, both `infra/dokku/` scripts, Backend CI's bucket-validation job and Backend CD's publish step — and Alembic 0034 dropped the mirrored tables and the `powersync` publication. Bucket definitions no longer exist anywhere, so the migration/publish ordering of [ADR-0017](./adr/0017-sync-rules-as-dokku-config-var.md) — and the manual two-phase procedure destructive migrations needed under it — no longer applies; that ADR stands as a record of the decision it made.
- **Architecture:** Follows the [12-Factor App methodology](./BACKEND_GUIDELINES.md) (stateless processes, environment-based configuration, etc.).

### The domain store

The domain read model lives in `jeeves_domain.sqlite`, a file **Drift owns outright**:
every application-visible name is a real table Drift created, `schemaVersion` is 1 with
`onCreate: createAll()`, and the next schema change is an ordinary `onUpgrade` step.

It is a *new* file. The name `jeeves.sqlite` belonged to a replication engine that is no
longer a dependency and that served those names as views over its own internal tables,
which is why the Drift schema had grown a 28-step ladder made mostly of `sqlite_master`
guards. The store is created rather than converted
([ADR-0035](./adr/0035-domain-store-cut-over-by-fresh-file.md)).

**The open path deletes nothing.** It creates `jeeves_domain.sqlite` and writes its own
replay marker; the predecessor `jeeves.sqlite` and its `-wal`/`-shm` sidecars are left
where they lie. An earlier build unlinked them on every launch, which this is a deliberate
reversal of (#673): a green-field build has no legacy store to migrate, so the deletion
bought nothing, and the directory `path_provider` resolves to is app-private only on
Android and iOS — on Linux and Windows it is the user's own Documents folder, where a file
of that name need not be the app's at all. Deleting by file name cannot tell the
difference, so it does not delete. A stale predecessor costs disk; the alternative costs
somebody else's data.

| Piece | File | Role |
|---|---|---|
| Open path | `app/lib/database/domain_store_io.dart` (+ `_stub`) | Resolves the documents directory, opens the file over `sqlite_async`, and reports whether the op log still owes it a replay. Touches no file it did not create. |
| Providers | `app/lib/providers/database_provider.dart` | `domainStoreProvider` (the opened file), `databaseProvider` (the Drift `GtdDatabase` over it, wrapped in `DatabaseConnection.delayed` so queries issued before the open resolves are queued), `domainStoreRebuildProvider` (the replay, plus the marker write and the failure log). |
| Replay | `app/lib/sync/domain_rebuild.dart` | Projects everything the local op log has reduced into a store that has not been projected into yet, through the same `DomainProjector` a pull batch uses. Idempotent, tombstones included. |

The replay is gated on a marker file, `jeeves_domain.rebuilt`, that only a *completed* replay
writes — not on the store's own creation. A replay that throws would otherwise be skipped for
ever on every later launch, leaving the log's reduced state stranded in a file nothing reads;
with the marker the next launch retries it, and a failure is logged. Creating the store clears
a stale marker, so a store deleted out from under the app is replayed into again.

An enrolled device therefore loses nothing across the cutover: its op log is the record and
the domain store is a projection of it. A device that never enrolled has no log, so its
store starts empty and stays whatever the user puts in it. **That is a steady state, not a
gap to be closed** — enrolment is opt-in and nothing routes the user into it
([ADR-0046](./adr/0046-enrolment-is-opt-in-and-nothing-routes-to-it.md)), so a device may
run local-only indefinitely. If the user does later choose sync, the initial upload carries
the store they already have onto the op log (ADR-0034); enrolling is not a fresh start and
costs them nothing they had accrued.

#### The `actions` table (issue #471 story 1, issue #472 story 2, issue #473 story 3, issue #474 story 4, issue #478 story 8, ADR-0001)

`actions` is the first-class Action entity that replaced the `todos.next_action_text` cursor. It is an owned entity keyed by a client-declared `id` (like `captures`), belonging to one Outcome via `outcome_id` (FK → `todos.id`, `ON DELETE CASCADE`), with a denormalized `user_id` for the per-user bucket. Columns: `text`, `role` (`planned` / `current` / `done` / `superseded`; the CHECK lives on the Drift column, not Postgres, mirroring `todos.intent`), `position` (planned-queue order, NULL otherwise), `energy_level`, `time_estimate`, `created_at`, `updated_at`, `done_at`. Per **ADR-0018** there is no `superseded_at` and no `superseded_by_id` — a superseded row's termination time is read from `updated_at`, and the Outcome's history is the time-ordered chain of terminated rows.

**Story 2 made the table live for writes; story 3 (issue #473) moved the reads onto it.** `ActionDao` (`app/lib/database/daos/action_dao.dart`) is the single in-app writer and owns the lifecycle primitives — `setCurrentAction` (create-or-in-place-edit; identical text is a no-op; never auto-supersedes), `editAction` (in-place field edit by id, role-agnostic, used by story 7 for metadata), `supersedeCurrentAction` (the explicit-affordance role flip — no linkage columns per ADR-0018; exercised by tests only this story, since the Abandon / re-clarify affordances that call it are stories 5/8), and `clearCurrentAction` (supersede with no replacement, the Action side of a blank cursor). The stamping rule is encoded once, in `ActionDao._stampOutcome`: every public primitive stamps `last_clarified_at` (an Action mutation is a clarifying micro-act — CONTEXT.md § Clarification); no-ops, the multi-current convergence repair, the reconciliation sweep, and — the one deliberate exception — `completeCurrentAction` do not. The 0..1-current invariant is app-enforced (no partial unique index — a unique violation would `500` → infinite retry), so any primitive that finds more than one `current` row first converges deterministically: keep the winner by greatest `COALESCE(updated_at, created_at)`, tie-break smallest `id`, retire the rest. Every write self-notifies (`notifyActionsViewWrite`, ADR-0010) after commit.

**The cursor is gone (story 9, issue #479, ADR-0022; dropped by #525, ADR-0024).** `actions` is the only grain: `todos.next_action_text` is not declared in `tables.dart`, is not carried by any collection codec, and is not projected by `TodoDao.todoProjectionSql`. The store is a fresh Drift-owned file (ADR-0035), so the column has never existed in it; `schema_baseline_test.dart` asserts it stays absent. The one-field surfaces survive as thin entry points that drive `ActionDao` and nothing else — `TodoDao.setCurrentActionText` (blank routes to `clearCurrentAction`), `TodoDao.setCurrentActionTextIfActionless` (issue #501 — the **atomic actionless-mirror**: reads the `current` Action and writes the Action inside **one** transaction, so a `current` Action landed by sync cannot slip between the check and the write; it takes `setCurrentActionText`'s write path verbatim through the shared `_applySetCurrentActionText` body when Actionless, and is a pure no-op — no write, no stamp, no notify — when a `current` Action already exists; blank text is a caller error), `TodoDao.applyRouting`'s `nextAction` / `waitingFor` arms (blank → clear, absent → no-op; the other arms write no Action), and `TodoDao.deleteOutcome` (carve-undo cascades the Outcome's Action rows explicitly — the op log has no cascade of its own, so the delete has to enumerate them for the peers that reduce it). Their atomicity and notify semantics are unchanged; only the storage moved, and the two text surfaces were renamed off the cursor's name onto the Action's (`setNextActionText` → `setCurrentActionText`) so no Dart identifier outlives the column.

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

The correlated `EXISTS` runs once per candidate Outcome, so `actions` carries a declared index on `(outcome_id, role)` — `@TableIndex` on the table class, asserted present by `schema_baseline_test.dart`. It used to be installed by the storage engine on its own backing table; a Drift-owned store has to declare it, and its absence would be a silent full scan that no other assertion notices.

The residual exposure is a cursor-only change arriving from a client that predates the Actions table: it re-emits the `todos` watchers while the reads come from an unchanged Action row, so a stale subtext can render mid-session. Nothing reconciles it, because no runtime code path reads the cursor at all. The cursor edit is simply ignored, permanently and by design. The Action row is the answer wherever the two disagree.

**Convergence is the writers' job, not a startup sweep's.** The 0..1-`current`-per-Outcome
invariant is app-enforced rather than indexed, so a cross-device race can reduce in two
`current` rows. Every `ActionDao` primitive that touches the current Action converges the set
first — `_resolveCurrentAction` retires the losers by the deterministic winner rule the
writers and readers both use (greatest `COALESCE(updated_at, created_at)`, tie-break smallest
`id`) — so every device collapses to the same row as it encounters the conflict. It retires
rather than deletes (ADR-0018 history), never mints a row and never rewrites an existing
row's `text`, and never stamps `last_clarified_at`: convergence is repair, not clarification
(ADR-0012).

The startup sweep that used to do this (`reconcileActionsAtStartup` /
`convergeMultiCurrentActions`) is **gone** (#595). It existed to repair a store fed by legacy
replication, and it ran raw SQL outside the capture seam — authoring no op — which was
defensible only while it had a store to repair. The writers cover the same case, in the
transaction that would otherwise observe the conflict.

**Three cursor-driven arms were deleted and must not return** (ADR-0022). Two treated the cursor as authoritative: one overwrote a `current` Action's text and metadata from the cursor, the other retired *every* `current` Action whose Outcome had a blank cursor. Both were consistent only while every write path dual-wrote the cursor; the moment it stops being written they become destructive — the first reverts every Action edit at the next launch, the second retires every current Action on the device. Removing them also retired a latent hazard: a sweep-retired Action stranded its open `time_logs` row, because the sweep runs no termination hook.

The third was **cursor adoption**, which minted a deterministic-id `current` Action for a live Outcome carrying a non-blank cursor and *no `actions` rows at all*. It looked safe — mint-only, monotone, and guarded on the Outcome having no Action rows whatsoever — and it was not. Its guard assumed every role transition leaves a row behind, but `ActionDao.applyRemovePlannedAction` is a hard `DELETE` (the Remove-vs-Abandon distinction of issue #478) and is the only mutation that drives an Outcome's Action count to zero while the `todos` row survives. On a store whose cursor was populated in the dual-write era, *demote the current Action then remove the planned row* left a live cursor over zero Action rows, and the next launch minted the just-deleted Action back as `current` and synced it everywhere. Deleting the pass makes that impossible by construction, and keeps `applyRemovePlannedAction` a hard delete. **The general lesson: a guard phrased over role transitions has a hole wherever a mutation leaves no row at all.**

The accepted cost is that an Outcome created on a pre-Action client and synced in renders Actionless until the user gives it an Action. Alembic 0028 covered the Outcomes that held a non-blank cursor *when it ran*, so for those the text is not lost — it is already a `current` Action. It is a **one-time migration, not ongoing reconciliation**: an Outcome a pre-Action client creates after 0028 has run carries no cursor the server will ever read, and nothing since 0028 mints Actions from Outcome data, so it renders Actionless. That is the recorded residual, not a covered case. A separate, genuinely unrecoverable residual is the never-synced local store, whose cursor text had no server copy to derive from — an explicit exception taken inside the alpha window (ADR-0024); the general durability question it raises is open as **#534**. The pass is clarification-neutral — it **never** stamps `last_clarified_at` (ADR-0012 spirit — never auto-stamp on drift) — and idempotent, so the steady state is one read and no writes at all.

The server (Alembic 0028) backfilled one `current` Action for each Outcome whose `next_action_text` was non-blank at migration time (blank / whitespace-only / NULL mint nothing, matching the app's actionless normalisation). It ran once and has no successor pass, so it says nothing about rows created afterwards. The two origins converge on a **single** row with no reconciliation code: the id is `uuid5(NAMESPACE_URL, "jeeves://action/backfill/<todo_id>")` computed identically in Python and Dart (`backfillActionIdFor`), every field derives only from replicated Outcome data (`created_at = COALESCE(last_clarified_at, created_at)`), and ADR-0015 upsert-on-replay collapses any duplicate upload (**ADR-0019**). A matching client-side backfill ran in the Drift v26 `onUpgrade` until #525 deleted it together with the column it read (ADR-0024); the server already holds every Action it would have minted, so a client reaching v26 today re-syncs them rather than re-deriving them. `backfillActionIdFor` and its cross-language golden vector stay in the client as the contract the server backfill mints against.

#### The two-stage boundary

Sync is two stages, and the seam between them is a hard boundary:

1. **UI ↔ local storage** — widgets, providers, and DAOs read and write the domain store.
2. **Local storage ↔ remote** — DAO writes are described through the capture seam and authored as signed ops; pulls reduce peers' ops and the projector writes them back into the domain store.

**Stage 2 is out of scope for all UI behaviour.** The UI's contract is with the local row and nothing else. It cannot determine — and must not attempt to determine — whether a local change originated from another screen, a background job, or a replicated delete from another device. "The row is gone locally" is the complete signal; there is no UI-visible notion of a *remote* delete, and a screen reacting to a subject disappearing is doing local-storage reactivity, not sync.

The practical consequence is about how UI behaviour gets *justified*, not just how it is implemented. Writing to a row absent from local storage is incorrect on its own terms. That a stray write would also author an op and be refused on the way in is a downstream symptom which confirms the bug — it is never the reason to fix it. A UI fix argued from its downstream sync symptom will be scoped wrong, because it optimises for the transport rather than the local invariant. UI feature code therefore does not reference the outbox, an op, a Workspace id or an HLC — the sole exemption is the informational status adapter below — and UI tests exercise local storage directly rather than a sync round-trip.

**Sync status is informational, never blocking.** The one stage-2 signal the UI may see is replication health, and `syncStatusProvider` is the only adapter licensed to source it: it maps both Workspace clients' `SyncHealth` — plus what the store says about enrolment — through the pure `syncIndicationFor` table, and feeds the app-shell drawer indicator. It yields a `SyncIndication` — the display state *and* whether there is anything to report — from **one** read, because the glyph and the tile's tappability must not be able to disagree about whether there is something behind the tap. The indicator renders that state and, when there is something to report, navigates to `/sync-health`; it decides nothing else. It is still the **one** presentation of sync state: Settings offers signing in or signing out and says nothing about how sync is going, because a second presentation is how a device that was syncing nothing came to display ''Sync active''. **Most standing conditions are not errors** — fourteen of the eighteen alarm kinds and every refusal report rather than alarm, so the red state means something of the user's is genuinely stuck (ADR-0044). Behaviour must never depend on it — no gating a write, disabling a control, or branching a flow on sync state. The offline-first contract is that every user action completes against local storage regardless of what stage 2 is doing. Reading sync status to decide *whether* something happens is a stage-2 dependency wearing a display read's clothing.

### Minimal Sync Server

**This is the production sync path** (#591, [ADR-0034](./adr/0034-sync-starts-at-enrolment.md)). A self-contained sync stack carries the whole domain — the content-blind op log of ADR-0026 plus ADR-0028's trust root — and the app writes and reads through it. It is the only one.

`app/lib/providers/sync_stack_provider.dart` opens its own `jeeves_sync.sqlite` — a file of its own, deliberately not the domain store's, because the domain store is disposable by construction (ADR-0035) — reads this Device's identity out of the platform key store, puts `HttpUserTransport` on `ApiService.sessionDio` so the User-credential sync routes ride the same session and the same 401 refresh as every other call, and attaches one `DomainProjector` and one `DomainReconciler` over the `GtdDatabase` — built on a single `CollectionRegistry`, because both read the same reduced state — to every client the stack builds. Assembling the stack does not start syncing; `providers/sync_lifecycle_provider.dart` does.

**Sync starts at enrolment.** `SyncLifecycle.activate` (`app/lib/sync/sync_lifecycle.dart`) is one closure with two callers — the enrolment outcome, and `main.dart`'s eager watch at every launch — and it runs its steps in a load-bearing order: derive enrolment state from the store with no network (`sync/enrolment_state.dart`; not enrolled or half-founded and nothing happens beyond settling the capture seam *silent*, an explicit decision because the seam buffers from construction); **bind the capture seam next, from those local reads alone**, before any network, so an enrolled device that writes on the first turn of a cold start authors that write rather than losing it to the async chain — binding drains the buffer the seam has been holding; re-mint the member credential by proof-of-possession over the stored keys if none is in hand (the credential is memory-only, so a relaunch has none) *inside the same `try` as the sync*, so an offline relaunch's failure to attach classifies as `syncFailed` — capture already bound, writes queuing — rather than escaping unclassified and leaving the session silent; sync both Workspace clients (re-fetching the preferences client from the factory after the attach, so it carries the freshly minted transport), because the initial upload's diff skip is only meaningful against a pulled log; run the **initial upload** if this account's marker is unset; start one `SignalListener` per Workspace and a debounced outbox flusher, without which a DAO-authored op would sit in the outbox until the next cold start.

**The initial upload** (`app/lib/sync/initial_upload_plan.dart`, `initial_upload.dart`) is what makes signing up for sync carry the store the user already has: it walks the twelve domain tables unfiltered, transforms each row into the exact op fields it will carry (ADR-0025's Area-exclusivity resolution included, `user_id` stamped with the enrolled account), and authors through `SyncClient.capture` — the production path, so the codecs, the author-side guards, the HLC, the signature and the outbox are the real ones. Idempotence is a **diff against reduced state**, not a memory of the run, so an interrupted pass resumes on the next sync with nothing re-authored; a per-account row in `initial_upload_state` records a *completed* pass and its report. On a second device the ceremony's own pull has already projected the first device's data into the domain store, so the walk is self-cancelling. Refusals (#573) are permanent data anomalies rather than retryable transport state: they are recorded in the marker's report and do not hold the marker open.

**The capture binding** is `WorkspaceRoutingOpCapture`: one instance at the `GtdDatabase` construction site (`providers/database_provider.dart`), which *buffers* the ops it is handed until the enrolment decision is made — a **decision, never launch timing, disposes of an op**. The lifecycle binds it (draining the buffer) once enrolled, or settles it silent (discarding the buffer) once not; while signed out, `syncLifecycleProvider` settles it silent as soon as session restore answers. Buffering from construction is what closes the window between the store becoming writable and the bind step, so a write on the first turn of a cold start cannot be lost. It routes by collection, because `user_preferences` entity ids are `uuid5(preferences_workspace_id, key)` and an op authored into the GTD Workspace would land in a log whose derivation nobody there shares.

- **`backend/app/sync/`** — eight tables and two credentials. `ops` (append-only per Workspace, `seq BIGSERIAL` as a transport cursor only), `members` (public keys plus `chained_at`, the server's own index of which registrations landed), `recovery_escrows` (one passphrase-wrapped Root per `(workspace, user)` slot), the append-only `recovery_escrow_fetches` audit, `workspaces` plus `grants` — the server's own index of which Workspaces exist and who holds what in them, authoritative for nobody as described below — and `keywraps` plus `workspace_epochs`, which hold one Workspace content key per `(Member, epoch)` and per `(Workspace, epoch)` respectively, in blobs the server can never open. The **User credential** reaches `POST /members`, `PUT`/`GET /w/{w}/recovery` and the proof-of-possession exchange; a **member-scoped token**, issued only against an Ed25519 signature over `"jeeves/auth-challenge/v1" ‖ member_id ‖ nonce`, reaches `POST`/`GET /w/{w}/ops`, `GET /w/{w}/members`, the three key-plane routes and `WS /w/{w}/signal`. `resolve_member_token` is the single site that resolves all of them, HTTP and socket alike, so the socket cannot become the weak door: a user session subscribes to nothing. `get_current_user` refuses a member token and vice versa, and every posted op must name the token's own Member as its author — one comparison, no crypto (F10). The separation holds for **refresh** tokens too, and in both directions: a refresh token is a row rather than a JWT, so `POST /session/refresh` refuses any record carrying a `member_id` and `POST /members/{m}/token/refresh` refuses any record without one — otherwise a Device would launder its member refresh token into a full user session and from there into the escrow. `POST /members/{m}/challenge` is unauthenticated on purpose (possession of the device key *is* the credential being proved) and therefore rate-limited: a per-member-id Redis counter capped by `MEMBER_CHALLENGE_DAILY_LIMIT` over `MEMBER_CHALLENGE_WINDOW_SECONDS`, checked after the existence lookup so id enumeration creates no counters, refusing with `member_challenge_rate_limited`. Both op uniqueness rules — `(workspace, author, op_id)` and `(workspace, author, author_seq)` — are database constraints, because the handler reads `MAX(author_seq)` before it inserts and two concurrent batches would otherwise fork an author's chain; a raced insert comes back as the idempotent duplicate or a 409, never a 500. Alembic `0031` adds the log and registry, `0032` the escrow and the identity columns, `0033` the `workspaces` and `grants` index, and `0035` the `keywraps` and `workspace_epochs` tables. `0035`'s downgrade refuses harder than its predecessors': theirs destroy an index a human could re-derive from the log, whereas dropping the key tables destroys every server-held copy of every Workspace content key — random, never derived, stored nowhere else — and makes all `aead_v1` history unreadable to any device enrolling afterwards.
- **`app/lib/sync/`** — the v1 envelope and control-payload codecs, HLC, `RootAuthority`, the recovery-escrow blob codec, `PassphrasePolicy`, `EnrolmentService`, `enrolment_state.dart`'s three-state store read (shared by the lifecycle and the ceremony surface, so the two cannot drift), the `DeviceKeyStore` seam (Keychain/Keystore in production, in-memory in the harness), `SyncStack` (the whole assembly, with the store, key store, User transport, domain store and clock injected, so the harness runs the *same* closures production does — including the per-call member-transport propagation onto the preferences Workspace's client, which a harness fake cannot stand in for; it also *holds* the User transport, so the lifecycle's proof-of-possession has that seam rather than a consumed copy, and the wall clock and merge-strategy registry, so a second reducer built over the same device — the reseed verification builds one to reduce the server log from zero — arbitrates under the same rules rather than a second copy of them), `sync_lifecycle.dart` (what starts syncing, and the initial-upload marker store) and `sync_store.dart`'s platform opener, a client-owned Drift store (`op_log`, `outbox`, `author_state`, `sync_cursors`, `quarantined_ops`, `integrity_alarms`, `root_pins`, `control_chain_state`, `applied_control_log`, `epoch_floors`, `initial_upload_state`, reduced state), the field-grain reducer with a collection registry, the per-author chain verifier, `SyncClient` over the two transport seams, `SignalSocket`/`SignalListener` for the subscription, and the initial upload (`initial_upload_plan.dart`, `initial_upload.dart`). Plus the four pieces that carry the domain across it, described below: the capture seam, the per-collection codecs, the merge-strategy registry, and the domain projector.
- **`spec/sync/`** — frozen golden vectors. `envelope_v1_vectors.json` pins the header at every field offset, the body framing and padding rules, all seven signing domains, the genesis, MemberRegister, Grant and Revoke certificates with their chain links, the escrow and challenge signature preimages, the Argon2id floor, and every fail-closed refusal; `reducer_v1_vectors.json` pins the merge rules, including the non-LWW strategies' lattice behaviour — a case may carry `permute` (the runner applies the ops in every order and expects identical reduced state) and `expected_clocks` (the stored per-field HLC, which a values-only case cannot observe). Both suites assert byte equality against the same files and neither regenerates them — `backend/tools/generate_sync_vectors.py` is run by hand, and re-running it is a protocol change.

**Content is opaque; two op classes are not.** The server reads the 158-byte header for its index columns and its content-blind authz, and never a content body. Two classes are the deliberate exceptions, both because the server has to *act* on the payload and therefore both `plaintext_v1` for ever: `op_class = 2` (ADR-0028, F2), so membership can be checked before it is materialised, and `op_class = 5` (#555), so `ops.compacted_by` can be stamped from a prune's target enumeration. The second costs no content-blindness — the enumeration is transport seqs, author positions and envelope hashes, every one of which the server already holds, and nothing about what any op said. Those two are the only body-reading paths in the routes. `op_class = 4` is **not** one of them: a compaction body is ciphertext once the Workspace is keyed, so its shape rules belong to every receiver and the routes treat it exactly as they treat content.

**The signal socket is the one push in the stack, and it carries nothing.** After the client sends its member token as the first frame (a browser cannot set `Authorization` on a WebSocket, and a query string would log the token), the server answers with a **poke** — a zero-length text frame meaning "run a sync from your cursor now" — and sends nothing else but that poke and the fixed keepalive literal `ping`, emitted only while the socket is idle. The Workspace is in the URL path, so no frame carries a seq, an author or a count, and coalescing is free: N appends before the subscriber wakes collapse into one poke, and the pull sweeps up everything past the cursor. The handshake's immediate poke doubles as the auth ack and the catch-up trigger, which is why the server keeps no per-subscriber state at all. The handshake is also the only part of a socket's life that holds a database session; it is released before the pump starts, because a session kept for the connection's lifetime parks a pooled connection idle-in-transaction per subscriber and starves HTTP once the pool is exhausted. Refusals close the socket: 4401 bad or non-member token, 4403 no grant, 4400 no auth frame within the deadline. Fan-out is `SignalHub`, in-process and single-worker by construction (see BACKEND_GUIDELINES.md §6 and §8). On the client, `SyncClient` stays a verb-set and `SignalListener` owns the subscription lifecycle: a poke means a pull — no directory refresh precedes it, because a MemberRegister is its author's op 1 and the pull hydrates the directory in `seq` order by itself — single-flighted with a dirty flag; a lost, silent or misbehaving socket rides an exponential backoff with full jitter; 4401 parks until the token refreshes; 4403 is terminal.

**The trust root.** Root is a random Ed25519 keypair, never derived from the passphrase, living at rest only inside the escrow blob and held by a Device just long enough for an enrolment ceremony or a passphrase change. A Device registers itself with a `member_register` control op — its own `author_seq = 1` — carrying a Root-signed certificate; Root never authors an envelope. The escrow's Argon2id derivation runs on a **background isolate** (`compute` in `recovery_escrow.dart`, which is `Isolate.run` wherever isolates exist and an inline call on web): the floor is 64 MiB at t=3 through a pure-Dart KDF, which is seconds of solid CPU, and on the UI isolate that is a frozen frame pipeline during the one ceremony a user watches. Clients pin `root_pk` on first successful unwrap (TOFU against the passphrase, not the server) and their member directory is **chain-gated**: a key is learned only from a MemberRegister the device verified itself, in six steps — parse, Root signature over the literal certificate bytes, certificate-names-this-author, envelope signature *against the certificate's key*, key-id match, then position and chain. `GET /w/{w}/members` is a bootstrap hint that verification never reads, so poisoning it is inert — and no client calls it at all: `MemberDirectory.rememberChained` takes a parsed certificate, so there is no code path by which the registry could populate the directory, and neither transport interface carries a read for it. The route stays because the server's own content-blind authz needs the index; if a client ever needs the read it belongs on `SyncTransport`, since the route requires an unrevoked member JWT. Ops from a Member with no verified registration quarantine as `member_not_chained_to_root`, and terminally: the release scan below re-admits chain-gap refusals only, so an unchained author's content stays refused.

**Workspaces, Grants and roles.** A User has two implicit Workspaces, each a `uuid5` derivation of the user id — the default GTD one and a User-global `user_preferences` one — and each brought into being by a `workspace_genesis` control op. Genesis **embeds its founding Device's registration**, because the founder's key is unknowable before the certificate parses and there is no earlier op to learn it from (ADR-0031); an all-zero `prev_control_hash` is genesis-only in both directions, so a truncated history is always detectable. Genesis authorship is *log-state-conditioned*: any device holding Root founds a Workspace whose control log it observed empty, which is what makes the ceremony's crash window recoverable. Observing an empty log enters the race rather than winning it, so two Root-holders can both author one; the server admits exactly one and answers the loser `genesis_not_first`, including when the interleave is only caught by the `workspaces` primary key at commit. That 409 is neither an accusation nor a wedge on the client: the queued genesis can never become acceptable, so it is dropped, the Workspace's author chain is rewound to what the log attests, and the ceremony takes the *other* branch of the same method — pull the winner's genesis, register into it. Losing costs one extra iteration and no extra code path. Membership is then `grant`/`revoke` control ops carrying granter-signed certificates under their own signing domains, with roles **owner | participant | compactor | suggester**; revocation is grant-granular. An `owner` Grant is Root-mint *and* Root-revoke — the symmetry is ADR-0031's — so revoking a Device takes the passphrase. Both halves of that ceiling are judged against the batch's own in-memory walk of the `grants` index rather than the table, so a Grant minted at index 0 of a POST counts for a revoke at index 1 of the same POST; the revoke half needs it, because a frozen revoke certificate names a `grant_id` and not a role. A `grant_id` is single-use — a *different* op reusing one is a 409 rather than a primary-key collision — and because control verification runs before the append resolves duplicates, the already-stored op ids are passed down and exempted, so an idempotent re-POST of the enrolment batch is a replay and not a reuse.

Authorization splits three ways on the server. The escrow routes take the User credential and admit either derivable Workspace. `GET /w/{w}/ops`, `GET /w/{w}/members` and the signal handshake admit any **unrevoked** member token whose User derives the Workspace, with no Grant required — that is what lets the ceremony pull the control log before it holds one, and a pre-genesis GET returns an empty page rather than an error. Content POSTs require a **live Grant** and dispatch on `(grant.role, header.op_class)`; a root-signed control payload lands regardless of Grants, which is how an ungranted device's register-plus-grant batch gets in. `workspaces` and `grants` are the server's own index, authoritative for nobody: a client derives its grants view from its applied control log and evaluates the verdict **at the op's own server seq** (`granted_seq < S < revoked_by_seq`), never against current state, so a late-arriving pre-revocation op still applies. Revoking a Member's last live Grant kills its refresh tokens *and* closes its live signal sockets, since a socket is authorised once at the handshake and never re-checked. A control fork is resolved by earliest certificate HLC then lowest author member id — the certificate's clock and not the op's, or a forking author could move the tie by re-signing an envelope around the same certificate — and the losing branch is quarantined along with every control op chaining through it. Because that can change which content ops were authorized, resolution triggers a full **rebuild from the op log** — the reduced state is a join-semilattice with no per-seq lineage, so there is no partial rewind — recomputing only the authorization verdict, honouring persisted `refused_reason` for reducer-guard refusals, and clearing a stale `no_live_grant` off an op the corrected view now admits. The rebuild reports every entity it touched **plus every entity that had reduced state before it started**: an entity whose ops all became refused reduces to nothing, so the replay names it nowhere, and a projector told only about what re-applied would leave its domain row standing as the last visible trace of a quarantined branch.

**Per-author chains are verified, and a misbehaving server is an alarm rather than data weirdness.** Every content op's position is checked against its author's **verified head**, derived from `op_log` at read time and never stored — a stored head would be a cache of the log, free to disagree with it. The verdict sits after `verifyEnvelope` and after the payload decodes, because only an authentic *and* codec-valid envelope may advance or accuse a chain; the append is a plain insert and never an upsert, so a slot already taken — the transport's `(workspace, seq)` primary key or the `(workspace, author, author_seq)` unique index that mirrors the server's constraint — is refused rather than written over: a server spending one `seq` on two *different* chain-valid ops raises `author_chain_slot_collision` and the second op is skipped, because the log is evidence and evidence is not edited. The alarm is judged on the bytes, not merely on the taken slot (#618): a re-served op whose row at that `seq` is byte-identical is this device's *own* reserve, re-served because a crash landed between the receive commit and the cursor save, and it is skipped silently and self-heals as the cursor advances — only divergent bytes at a held slot are the accusation. Any *other* database failure on that append propagates and aborts the pull with the cursor unmoved, so a transient error is an op the next sync retries rather than one permanently skipped under a collision label it never earned. A control op and a prune apply as **one transaction** — the `op_log` row, the authority effect (a raised epoch floor, an `applied_control_log` append, or a `pruned_attestations` insert) and the `applied_at` stamp commit or roll back together — so a process death mid-apply leaves all of it or none, never a raised floor with no applied-control record behind it; a refusal still commits its logged-but-refused row, and a genuine storage fault is the only thing that rolls the unit back. Everything else that escapes the receive pipeline un-classified — a parse, verify or decode path throwing something that is not a `SyncRejection` — is quarantined as `unexpected_receive_failure` rather than propagating, because an error thrown before the cursor advances would have every later pull refetch and re-throw on the same op: fail-closed has to be total, or one adversarial envelope wedges the receive indefinitely. `op_log` admits every chain-valid envelope even when a reducer guard then refuses its payload, marking the row with `refused_reason` and leaving `applied_at` null — withholding it would make the author's honest next op read as a gap — and `_clock.receive` fires only on a successful apply, so a refused future timestamp cannot poison the local clock. Two vocabularies come out of it: a **quarantine reason** per refused envelope (`author_chain_gap`, `prev_author_hash_mismatch`, `author_chain_rewrite`, `duplicate_op_id_divergence`, `stale_replayed_op`, `own_writes_divergence`, `unexpected_receive_failure`, and the two encryption ones that are receiver state rather than bytes — `missing_epoch_key` and `plaintext_at_encrypted_epoch` — all client-only codes, since a chain rule is stateful receiver policy rather than a codec rule, so no golden vector carries one) and an **integrity alarm** per standing accusation, upserted by `(workspace, kind, author)` so a server re-serving the same evil bumps a counter instead of flooding rows — a unique index, not merely a convention the writer honours, except for the server-only alarms that name no author, which SQLite's distinct-NULLs rule leaves to the select-then-write path. Both that index and the chain-slot one are created behind a **pre-flight duplicate check** that fails the migration with the invariant and the recovery named, because the alternative — de-duplicating the rows first — would edit the evidence to let a schema change through, and because no store predating those rules was ever one the server had seen: op-log stores shipped empty until the #591 flip, so the affected stores are dev and harness stores, which are disposable. From #591 on, a device's store is authored into at enrolment and a store that trips the check is one to recreate rather than a rounding error. Reorder heals to fixpoint: each accepted op re-asks which quarantined envelopes claim head + 1, in one flat loop with re-entry suppressed, and a released row keeps its `released_at` for inspection. The early release is what makes that loop terminate, but it is also the one thing that would strand a **replay** on a storage fault: the winner was pulled during an earlier sync, so the cursor is long past its transport seq and nothing re-serves it, and re-serving its already-logged predecessor does not re-run the scan — so the winner's release and re-receive run as **one transaction** that rolls the release back on a `SqliteException` (keeping the row a claimant), and a durable `release_started_at` marker written only for that winner re-arms the scan on the next pull (`_hasInterruptedChainReplay`), restart-safe across process death. A standing fork never becomes a winner, so it never carries the marker and never re-churns its alarm. Several envelopes can claim one position, so the scan releases the claimant whose `prev_author_hash` verifies against the verified head rather than the one the server happened to serve first — a forged alternate quarantined before the genuine op arrives cannot block the genuine successor, because the head's envelope hash is the one tiebreak the server cannot forge. Every claimant that does not chain is `author_chain_fork` and stays refused — and so is every byte-different claimant that *does* chain past the first, since a gap row exists only after the envelope signature verified, so two of them mean the author signed two continuations of its own chain; because the fork alarm upserts by `(workspace, kind, author)` it counts occurrences rather than enumerating claimants. `author_stream_reordered` is raised whenever the scan re-admitted anything; the *gap* alarm is resolved only once no unreleased gap row remains for that author, so a refused claimant leaves the gap standing beside the reorder. So drop, reorder and fork end in three distinguishable states, and withholding stays detectable rather than preventable. The pull cursor never regresses, staleness is judged against the `since` the page asked with (an op above it arriving out of order is a reorder, not a stale prefix), and a page with no forward progress ends the pull. The flush posts the queue in `maxOpsPerBatch` chunks in `author_seq` order, each acknowledged before the next goes out — the one number the server's `MAX_OPS_PER_BATCH` mirrors, exported so the two cannot drift, since a device that authored more than the cap offline would otherwise re-POST the same oversized batch for ever and never drain the queue the outbox exists for. Authoring is serialised for a related reason: the chain head is read before the envelope is signed and advanced after, so two un-awaited `capture()` calls would both mint an envelope at one `author_seq` — a fork this device signed against itself, which no constraint catches, because the `(workspace, author, author_seq)` unique index guards `op_log` and neither `outbox` nor `author_state` holds that key. Authoring is also **fail-closed through the receive path's own codec**: `capture()` runs its payload through `frameBody → parseBody → OpPayload.decode` and `captureControl()` through the stateless prefix of control verification (`decode` → served type → chain-link shape) *before* signing, and the reduce takes the decoded payload — so a wire-invalid payload is a thrown `SyncRejection` at the write site with the store, the outbox and the author chain untouched, instead of an op that applies locally and is then quarantined by every peer and by its own author's echo, and the author reduces exactly the object its peers will decode. The state-dependent stages of control verification stay receive-side, because their inputs are the receiving device's state and a second copy of them would be free to disagree with the first. A 409 on our *own* POST is judged against the retained outbox: `own_writes_rollback` when the server's expected position is at or below what it already acknowledged (the detail names both possible causes — a rolled-back server, or this device restored from an older backup — because the client cannot tell them apart), fail-closed with nothing re-numbered, and the flush wedge never blocks the pull. Its two siblings in the own-writes family are `own_writes_divergence` and `own_write_refused_permanently`, the latter raised when our POST is refused under a code no retry can change so the queue behind it cannot drain. `SyncHealth` reports it: `clean` is derived from `pending_op_count == 0 && unresolved_alarm_count == 0`, so it cannot read clean over a stuck queue or a standing accusation. A chain gap covered by a verified prune op is **not** an alarm, and that is what the verified chain floor is for (#555): the verdict takes a floor `({seq, envelopeHash})` and the floor **wins above the derived head**, because entity-level pruning punches holes *inside* an author's chain rather than truncating a prefix — a device may hold positions 1-2 and have to verify 41 across attested ones. It is sound because the caller walks the floor contiguously forward from the real head over `pruned_attestations`, so every step above the head is individually attested and hash-linked; below the head the log is the better evidence and wins. A prune being *judged* additionally bridges with its own signed enumeration, because in the v1 shape the owner device self-compacts and its prune therefore sits above the holes it attests — judged against stored attestations alone it would gap for ever and nothing would ever apply it to create them. Applying a prune then cross-checks each attested position three ways: against the attestation table, against `op_log`, and against `quarantined_ops`. A matching quarantined gap claimant is **settled** — released without re-receiving it and with no alarm, since it and the compactor agree byte for byte — which is what lets an honest post-compaction bootstrap read clean at fixpoint rather than as an alarm storm. A divergent one stays quarantined under `prune_attestation_divergence`, and the gap alarm stands with it. `_hasUnreleasedGap` is unchanged and the gap alarm still cannot resolve for that author: nothing here reclassifies a settled position, and with every alarm resolution deferred there is no recorded decision for such a predicate to honour. What did change is what the *user* is told — the gap alarm standing no longer means the log is broken beyond the one author it names, and a `prune_attestation_divergence` beside it reports rather than alarms (ADR-0044).

Protocol identity: envelope = 158-byte header ‖ body ‖ 64-byte Ed25519 signature, with AAD defined as the literal header bytes so the `aead_v1` swap changes only the body; body = `u32 payload_len` ‖ JSON ‖ zero padding to `{256, 1024, 4096, 16384}` or, above that, the next 16 KiB multiple; suite `0x00` = `plaintext_v1`, `0x01` = `aead_v1`; op classes 1–5 named, `1=content`, `2=control`, `4=compaction` and `5=prune` served (`#555`), with `3=suggestion` fail-closed on both sides until `#557`. Control ops chain across authors by SHA-256 over the predecessor's *payload bytes*, which is why every control payload must carry a `type`. Seven domain-separated signing prefixes, one per document a signature can be over: `jeeves/op/v1`, `jeeves/member-register/v1`, `jeeves/auth-challenge/v1`, `jeeves/escrow/v1`, `jeeves/workspace-genesis/v1`, `jeeves/grant/v1`, `jeeves/revoke/v1` — a new certificate kind gets its own prefix rather than sharing one, so a signature over one document can never be replayed as a signature over another. Ordering is HLC `(wall_ms, counter, member_id)` — `seq` is never a merge input. Deletion is a tombstone op. Every route rejection carries a structured `{"code": …}` detail, with the batch `index` on per-op failures.

**The `aead_v1` suite and the key plane, end to end (#554).** Both codecs serve suite `0x01` — the body is XChaCha20-Poly1305 over the *same* framed body `plaintext_v1` would carry, with the literal 158 header bytes as AAD, so the padding rules run on the decrypted plaintext through the same function and the suite, epoch and nonce are bound with no second binding. Exactly one rule is suite-conditional (a `0x01` body is a size class plus the 16-byte tag), and two pairs are forbidden outright, one per class the server has to read: an `op_class = 2` op under `0x01` is `encrypted_control_op` and an `op_class = 5` op under `0x01` is `encrypted_prune_op`, because the server materialises those payloads and holds no key. The rule runs the *opposite* way for the classes that carry entity state: a `0x00` body at an epoch the reader holds a key for is `plaintext_at_encrypted_epoch`, and #555 extended that family from content to compaction — a class-4 op carries the whole joined state of an entity. Both KeyWrap flavours, the `keywrap_digest`, and the `rotate` control op are vector-pinned (ADR-0037). Server-side: alembic `0035` adds `keywraps` and `workspace_epochs`, `PUT /w/{w}/keywraps` accepts a whole wrap set only when it hashes to the digest the signed `rotate` already committed to, `GET /w/{w}/keywraps/me` and `GET /w/{w}/epoch-keys` serve wraps the server cannot open, and a content POST more than one epoch behind `MAX(workspace_epochs.epoch)` is refused `key_epoch_stale`, one above it `key_epoch_unknown` — no wrap set exists for an epoch nothing rotated to, so the op could never be read.

Client-side, **encryption is a fact about the epoch rather than a mode**: a content op is sealed iff the device holds `K_{w,key_epoch}`, so there is no switch, no per-call flag, and no way for two ops at one epoch to disagree about the suite. Above epoch 0 the missing key is the one case that fact cannot be read off the key alone, and it is a refusal rather than a downgrade: an epoch exists above 0 only because a `rotate` created it, so authoring `plaintext_v1` there would put content on the server in the clear at an epoch every peer holding the key refuses — `missing_epoch_key` at capture is the write boundary matching `plaintext_at_encrypted_epoch` on read. Epoch keys live in `WorkspaceKeyStore` — the platform keychain, deliberately *not* the sync database, whose at-rest posture is review F22 and unclaimed — and every epoch is kept for ever, because soft-delete retention means content at any past epoch may still have to be read. The receive path is a two-branch dispatch on the same question: `0x01` with the key opens under the literal received header bytes and runs `parseBody` on the plaintext; `0x01` without it is `missing_epoch_key`, quarantined and healed by a bounded KeyWrap re-fetch at the end of the pull; a `plaintext_v1` *content* op at a keyed epoch is `plaintext_at_encrypted_epoch`, the read boundary that keeps the upgrade one-way — judged on the epoch (anything above 0, plus epoch 0 where a key is held) rather than on whether the reading device holds the key, so a device still awaiting its wrap refuses the same bytes its keyed peers refuse instead of quietly reducing cleartext. `rebuildFromOpLog` goes through that same dispatch rather than a second decode — a rebuild that ran `parseBody` on an `aead_v1` body would find every encrypted row unparseable and quietly un-reduce the Workspace. `aead_failure` and `plaintext_at_encrypted_epoch` are integrity **alarms** as well as quarantines (the proposal's normative rule: AEAD failure is never a skipped row); `missing_epoch_key` accuses nobody. Because the Ed25519 signature covers `header ‖ body` and the order is verify-then-decrypt, a tampered ciphertext is `signature_invalid` — an `aead_failure` means bytes the author really signed that still do not open.

Two ceremonies mint an epoch, and both need the passphrase, because a new epoch's escrow wrap is minted under `master_wrap_key`. **Turning encryption on *is* a rotation**: the owner mints `K_{w,N+1}`, authors `rotate(N → N+1)`, publishes the wrap set, and seals content under the new key from then on — so every op already in the log stays at an unkeyed epoch and stays readable for ever. **`revokeAndRotate` is one ceremony rather than two**, since a revocation alone stops a Device authoring and does nothing about the key already on it. Nothing is authored until every survivor's wrap exists (review F14a): the set is built first, and an unwrappable survivor — today, a live-granted Service, which has no per-User KEX subkey yet — raises `unwrappable_grant` with the log untouched. **The publish is made durable before the rotate is authored (#617)**, because `WorkspaceKeyCeremony.publish` PUTs the wrap set and only then remembers the key: a crash after the flush has materialised the rotate but before the PUT lands would otherwise strand the epoch with the floor raised on every device and nobody holding `K_{w,N+1}` — unreconstructable, since a second `prepare` draws fresh entropy and cannot reproduce the committed digest. The prepared set (`workspaceKey`, member wraps, escrow wrap, digest) is persisted to a keychain-tier `PendingRotationStore` — the same at-rest tier as `WorkspaceKeyStore`, never the sync database, which would hold `workspaceKey` in the clear — before the `rotate` is authored, so no interleaved lifecycle flush can materialise a rotate ahead of its record. `EnrolmentService.resumePendingRotations` re-publishes any set whose rotate materialised but whose key was never remembered, passphrase-free (the record carries every byte the PUT needs), triggered from the next ceremony, the pull tail (`SignalListener.onSyncComplete`) and launch; the byte-identical re-PUT is a 200 (server-side idempotency, #590), the record is deleted once `publish` remembers the key. **A refusal is classified rather than assumed transient (#627).** The resume makes two server calls and they are not interchangeable: the per-Workspace `flushOutbox` that drains a rotate authored but never flushed, hoisted out of the per-epoch loop precisely because its refusal is not attributable to any one pending record, and the per-epoch `PUT /w/{w}/keywraps`. `rotation_resume_refusal.dart` is the pure table over `(statusCode, code)`, with **no `default: retry`** — transient statuses are matched positively and anything not positively matched gets a bounded per-process budget, so a future server code cannot silently rejoin the retry-forever path that was the defect. A publish refused under a table-classified permanent code (`keywrap_digest_mismatch` and the rest of the keywraps verdicts) raises `epoch_key_set_unpublishable` and marks the record **terminal and retained** — never deleted, because clearing a stuck state by destroying the only bytes that satisfy a committed digest is the same error at a smaller scale; the alarm is written *before* the mark, so a keychain failure cannot leave a silent terminal record. An unclassified refusal alarms on budget exhaustion and persists nothing, so a relaunch re-attempts and no unknown code ever becomes durably final. A permanently refused *flush* raises `own_write_refused_permanently` — Workspace-scoped, epoch-agnostic, and it never terminalises a record — which names the wedged-queue condition that #647 drains. A record whose rotate never materialised is discarded as `rotate_not_materialised`, but **only after a flush that succeeded**: otherwise the delete would destroy a wrap set whose rotate is still in the outbox, so it is downgraded to a retry. A failed flush does not skip the publishes, and a local store or alarm-write failure holds the error and continues rather than abandoning the remaining epochs. **Ceremonies serialize per-User through completion (#624)**: a per-instance ceremony lock on `EnrolmentService` (the future-chain idiom, with two modes) makes a second `rotateWorkspaceKeys`/`turnOnEncryption`/`revokeAndRotate` for one User **wait** for the first — so two overlapping ceremonies never both read one `epochFloor`, prepare distinct sets for one `toEpoch`, and race the `put` — while the resume triggers **try-acquire and skip** when a ceremony holds the lock, staying non-blocking so the pull loop and activation are never stalled behind a ceremony; the internal ceremony-then-drain call takes the *unlocked* core so it cannot re-enter the lock it holds. With that in place `ConflictingPendingRotation` no longer fires on the honest path and stands as the last-resort backstop against a bypass of the serialization. Applying a verified rotate raises `epoch_floor`, which finally has a raiser. A device enrolling into an encrypted Workspace adopts every epoch key from the escrow wraps and uploads nothing: an epoch's wrap set is immutable once written (that is what stops a hostile server curating it), and the keys are in its own store from then on. Scheduled rotation *reports* — an epoch older than the interval is surfaced as due, with the age read off the signed log rather than off `epoch_floors.raised_at`, which is a local clock two devices would disagree about. A freshly founded Workspace can be keyed at epoch 0 and encrypted from its first content op; the default is off, so landing this changes nothing about what an existing deployment emits and the byte-inspectable log #553's cutover verified against stays readable for ever.

**Entity-level compaction, with soft-delete prunes (#555).** A compaction pass authors two ops: a class-4 **snapshot** of one entity's joined state, read out of `reduced_fields`/`field_clocks`/`row_tombstones` — which *are* that join under ADR-0030's semilattice laws — and a class-5 **prune** enumerating what the snapshot supersedes. Every field of a snapshot carries the clock that won it and a tombstone carries `tombstone_hlc`, so merging one is absorption rather than a fresh write by the compactor: a pending edit at an older clock loses exactly as it would have lost against the original op, one at a newer clock wins exactly as it would have won, and an equal clock is an idempotent skip, which is why a full-history device applies a snapshot as a no-op. A field with no clock of its own is refused (`compaction_field_without_hlc`) rather than defaulted, because the op-level fallback is the compactor's newer clock and would win merges the original op would have lost. `tombstone_hlc` is fenced to class 4 and refused everywhere else, so it cannot become a way to backdate a deletion.

The pair is authored through the ordinary authoring lock and awaited in order, so the snapshot always takes the earlier `author_seq` and the flusher presents compaction-before-prune; the server's ordered batch walk stages class-4 `op_id`s from **headers** (a class-4 body is ciphertext) so the pair is legal in one POST and equally legal split across two. Materialisation stamps `ops.compacted_by` under an `IS NULL` guard and checks the rowcount — with duplicate targets refused at decode, a mismatch has exactly one cause left, a concurrent prune, and the loser gets the same `prune_target_already_compacted` the sequential case gives it. **Nothing is deleted**: the default pull hides a stamped row and `include_compacted=true` serves it back, behind the same member-GET bar as any other pull, because a prune hides history from the *sync* path and the User is still owed it.

Compaction refuses more than it performs. The device must be caught up — an undrained outbox means the snapshot would not be the join of everything — and must have no standing Integrity Alarm, since snapshotting state it has itself accused would launder the accusation into a signed op. An entity must be over a live-op threshold, and quiet for a grace window applied to the entity as a whole, which protects the devices still holding its history and means a freshly reseeded log is not a candidate until it ages. Control ops and prunes are never targets, on both sides. `captureCompaction` self-applies and asserts the apply changed nothing — the cheapest place to catch a snapshot whose clocks are not the joined ones — and deliberately does *not* insert its own attestations: those land on the prune's own echo through the ordinary class-5 receive path, one code path for every device, which makes the echo a self-check against the very rows they were minted from.

Stubs still left for the siblings: `member_key_rotate` and the remaining control types (rotating a *Member's* own signing or KEX key, as opposed to the Workspace content key `rotate` moves — `unsupported_control_type` is their landing slot); alarm **resolution** — the sync-health screen (`/sync-health`) accounts for every standing condition in plain language, and offers no button on any of them: `tookUpstream`, keep-ours and reject-permanently are deferred with #575, and until one of them exists only one alarm kind has any code path that can clear it, so almost every alarm this device raises stands for ever; cross-author fork detection, which needs `observed_head` (still zeroed) and author heartbeats, so author silence stays indistinguishable from offline; the passphrase-*change* screen, since `changePassphrase` still has no caller; the **UI for the key ceremonies** — `turnOnEncryption`, `revokeAndRotate` and `workspacesDueForRotation` are reachable only from tests, so no screen offers turning encryption on, retiring a Device, or the quarterly rotation prompt; **Service KeyWraps**, which need a verified per-User KEX subkey (#557) and until then make a Workspace with a granted Service unrotatable; **re-encryption of pre-turn-on `plaintext_v1` history**, which is its own issue because truly removing the superseded rows needs a one-time hard delete against the standing soft-prune stance; **automatic** compaction scheduling — `Compactor.compactionCandidates()` names the work and nothing runs it on a timer yet — along with the 180-day tombstone-retention floor and the stale-member cutoff, which need the stale-device reset path; and hard deletes, which v1 makes deliberately impossible. The server-side mirrored tables and their REST routes are gone — #556 retired them.

#### Two stores, and the path between them

Every device holds **two** stores, in two files, by design. The `SyncDatabase` (`jeeves_sync.sqlite`) is the collection-generic convergence substrate — reduced fields, per-field clocks, tombstones, the received log — and it is what "byte-identical convergence" is measured over; a device that has not shipped a feature still reduces its peers' writes rather than losing them. The `GtdDatabase` (`jeeves_domain.sqlite`) is the domain read model. Reduced state reaches it through a projector, never the other way round.

Two files rather than two schemas in one: the domain store is disposable by construction — it is deleted and rebuilt by the store cutover, and could be again — and putting the evidence in the same file would put it at the mercy of an operation whose whole premise is that the read model can be thrown away.

| Piece | File | Role |
|---|---|---|
| Capture seam | `app/lib/sync/domain_op_capture.dart`, `app/lib/database/gtd_database.dart` | What every domain write describes its effect through. **A capturing scope *is* one transaction:** `GtdDatabase.capturing` runs its body inside `transaction(...)`, buffers every described effect, coalesces per entity, and emits only *after the transaction commits* — so a rolled-back write is never signed (issue #598) and a committed write can never lose its op, in both directions. A method that touches one row three times authors one op; scopes nest and only the outermost emits, the inner being a savepoint that merges into the outer commit. Each scope carries its own buffer and is closed by the token `beginScope` returned, not by stack position — two overlapping un-awaited `capturing` calls must not be able to close, or flush, each other's scope; on commit a scope's ops merge into its innermost still-open ancestor and flush on their own only when no ancestor is still open. **Which scope a write belongs to, and which scope a nested one nests inside, are both read from the zone** `capturing` runs its body in (ADR-0042): the live scope rides that zone, per seam instance, so a described effect is filed into the scope of the execution context that described it — at any nesting depth, across every `await`, and with no handle threaded through the write verbs, which is what keeps write sites nobody has written yet correct. Overlap is ordinary rather than exotic: `capturing` opens its scope as its first *synchronous* statement while its body waits behind drift's `ensureOpen`, so two un-awaited calls always both open before either body runs — and because parenting is zone-derived, an overlapping scope is a stranger rather than an ancestor, so neither can flush or discard the other's ops. A described effect with **no live ambient scope, or one whose scope has already closed, is refused** (`StateError`) rather than filed anywhere: a dropped op is a committed row nothing will ever author, which is unrecoverable in a way a thrown error is not. `uncapturedTransaction` and schema migrations run with the ambient scope *masked*, so their "authors nothing" is enforced rather than incidental. A bare `GtdDatabase.transaction` outside a capturing zone is **refused** (`StateError`): domain writes go through `capturing`, and writes that must author nothing — the projector materialising already-logged reduced state — go through `GtdDatabase.uncapturedTransaction`. The guard reaches db-object callers only: a DAO is a `DatabaseAccessor`, so a DAO-internal bare `transaction` would bypass the override — moot in practice, as no DAO spells `transaction`. Production binding is `WorkspaceRoutingOpCapture`, built at `databaseProvider`; it buffers the ops it is handed until the enrolment decision — bound (drain and author) once enrolled, settled silent (discard) once not — so a decision, never launch timing, disposes of an op, and an un-enrolled device authors nothing. |
| Per-collection codecs | `app/lib/sync/collection_codecs.dart` | Twelve collections named after their tables, their synced columns, and the one canonical value encoding. |
| Merge strategies | `app/lib/sync/merge_strategy.dart` | ADR-0011's Conflict Strategy registry riding on the reducer, behind the ADR-0030 lattice requirement. |
| Domain projector | `app/lib/sync/domain_projector.dart` | Turns reduced state into typed rows, once per pull batch, and fires the ADR-0010 self-notifies. It **authors nothing** — the one sanctioned un-captured domain transaction — which is what makes it a pure function of reduced state and therefore order-independent for free. It returns the collection groups whose rows it wrote, which is the reconciler's trigger. |
| Domain reconciler | `app/lib/sync/domain_reconciler.dart` | Takes the convergence *decisions* the projector must not, because they have to reach peers and therefore author ops. Two passes with independent detection queries: **fold** a duplicate `(name, type)` Tag group onto `MIN(id)`, then **rehome** any junction row whose `tag_id` has no row in `tags`. Driven from the two projection batch tails — `SyncClient.pull()` and `rebuildDomainFromOpLog` — and never from `project()` itself, where its own ops would re-enter through the capture seam and recurse. The author path and compaction skip it deliberately: a local write goes through `findOrCreateTag`, which cannot mint a duplicate, and a compaction self-apply is a provable no-op. A pass that **throws never fails the pull**: by then the ops are durable, the cursor has advanced and the projection has committed, so propagating would skip the completion stamp and rebuild the very defect #605 repaired. The failure is swallowed and re-armed, and the next pull runs the passes whatever it touched — both detect from durable state and are idempotent, so a retry finds the same work and finds nothing once it is done. See ADR-0043. |

**Value encodings are protocol surface.** Drift `dateTime` columns encode as an ISO-8601 UTC instant truncated (never rounded) to exactly three fractional digits with a trailing `Z`; TEXT timestamp columns pass through byte-for-byte as opaque strings; text, int, bool and null pass through as JSON natives. The initial upload (`app/lib/sync/initial_upload_plan.dart`) reuses these codecs, so it cannot emit anything else. The *reading* half — `parseTimestampUtcMs`, whose grammar is deliberately wider than what the encoder emits — lives beside them in `collection_codecs.dart`, because a store written before the encoding existed holds microsecond- and offset-bearing strings that must map onto the truncated wire value rather than being refused. It is the sole definition of that tolerance: the golden vectors that used to pin it against a server-side serialiser retired with the mirrored schema (#556), so widening it is a protocol decision rather than a local one.

**Entity ids.** Normal collections keep client-random UUIDs. Two exceptions, both deterministic: `user_preferences` derives its id from `(workspace, key)`, and **junctions derive theirs from their pair** — `todo_tags`, `capture_outcomes`, `capture_tags`, `focus_session_dispositions` already did, and `focus_session_tasks` joins them via `focusSessionTaskIdFor`. A junction's domain identity *is* the relation, so two devices assigning the same tag offline converge as one entity instead of forking. Where the local `id` column is not the derivation (`focus_session_tasks`, `user_preferences`), the projector realigns it on every device.

**A Tag's op-log identity is its `id`; `(name, type)` is only its user-facing one.** Tag ids are client-random by rule, so two devices each creating "Alice"/`person` offline fork into two entities — and People are `Tag(type='person')`, so this is the ordinary multi-device case rather than an edge one. `tags` therefore carries **no** `(name, type)` uniqueness constraint: it is a projection of reduced state, and reduced state holds both. Uniqueness is an **eventual** invariant instead — enforced locally by `TagDao.findOrCreateTag`, converged across devices by the reconciler's fold onto `MIN(id)`, and repaired by its rehome pass. `user_preferences` keeps its `UNIQUE (user_id, key)` for the opposite reason: its id is derived, so two devices writing one preference are two writes to one entity. ADR-0043 records the whole trade-off, including why ranking the fold by reference count would kill both Tags.

**No implicit cascades.** The log has no foreign keys, so every deletion enumerates its cascade set at capture time. `deleteOutcome` — the one hard-delete path, reached only by the clarification-retraction orphan gate — tombstones the Outcome, its Actions, its `todo_tags` and its `capture_outcomes` links, and nulls `time_logs.action_id`. That is deliberately *wider* than the shipped local delete, which left the rest to the server's `ON DELETE CASCADE`; on the authoring device the projector applies the widened set. The cascade is gated on the Outcome's existence: a delete that removed nothing authors nothing, because a tombstone for a `todos` row this store never held is a delete a peer that *does* hold the Outcome would faithfully apply — and because the cascade enumerates by `todo_id`, an ungated one would sweep up junction rows and `capture_outcomes` links that survived an earlier delete (the projector never enforces referential existence, so those survivors are routine). Time data is never destroyed: a TimeLog outlives its Outcome and renders as *elsewhere*. Trash is not a delete — it is a plain `intent` field write on a live entity. The Tag fold enumerates its own set for the same reason: it repoints **both** junctions that reference `tags.id` (`todo_tags` and `capture_tags`) and tombstones each moved-from junction explicitly, because with enforcement off an orphaned junction is not an error but a silently invisible Tag assignment or tag hint. `TagDao.merge` still repoints only `todo_tags` and so still orphans tag hints; that is filed as its own fix.

**`SyncHealth`** (`app/lib/sync/sync_health.dart`) is what the sync indicator reads: queue depth, unresolved integrity alarms and their kinds, quarantine count, and a `lastSyncedAt` stamped on **pull completion, independent of flush state**. `clean` is a derived getter, never a stored status — a wedged outbox shows through `pendingOpCount`. Beside the raw counts sit two **class-filtered** ones — `actionableAlarmCount` and `reportableQuarantineCount` — and the two predicates over them: `degraded` (an `actionable` alarm stands: the only thing that makes the indicator red) and `hasSomethingToReport` (any unresolved alarm, or a refusal that is not self-healing: the only thing that makes the sync-health screen reachable). `unresolvedAlarmCount`, `quarantineCount` and `clean` keep their exact prior meanings, so the compaction blocker that reads the first of them is untouched. Every count comes from **one SQL string**, whose `IN (…)` lists are generated from `sync_condition_class.dart` rather than written out, so the query and the classification cannot drift. That file is also the one home for **classification**: what class a stored `kind`/`reason` falls under is domain state the sync tier owns, while every word the user reads about it lives in `screens/sync_health/sync_health_copy.dart`. The split is what keeps the dependency pointing the prescribed way — a `SyncHealthCondition` carries a code, a class and timestamps, and the screen resolves the sentence, so nothing under `sync/` imports a screen. `syncStatusProvider` maps it (both Workspaces' health, so a wedged preferences queue is a wedged device) through the pure `syncIndicationFor` table. It reads nothing else: the engine status stream it used to fold in sat permanently idle and mapped to `synced` — a green light on a device that was not syncing at all — and the dead-letter count went with the uploader that wrote it.

## Platform I/O Adapters

Any code that opens a file, spawns a process, or calls a native OS API must be isolated behind a platform adapter using Dart's conditional import mechanism. This keeps `dart:io` out of shared provider and service code so the app compiles cleanly on web without `if (kIsWeb)` branches scattered through business logic.

### The pattern

Three files per adapter:

| File | Compiled on | Responsibility |
|---|---|---|
| `*_stub.dart` | Neither (analyser only) | Throws `UnsupportedError` — gives the analyser a type to resolve on all targets |
| `*_io.dart` | Native (dart:io) | Concrete native implementation; may import `dart:io`, `path_provider`, etc. |
| `*_web.dart` | Web (dart:html) | Concrete web implementation; may import `dart:js_interop` etc. Only where a real web capability exists — the two store adapters stub out instead. |

The entry-point file uses a conditional export to pick the right implementation:

```dart
export '*_stub.dart'
    if (dart.library.io)   '*_io.dart'
    if (dart.library.html) '*_web.dart';
```

**Rule:** any new platform-specific I/O must follow this pattern. Never add `if (kIsWeb)` branches inside provider or service code — put platform divergence in the adapter file.

### Current adapters

#### `app/lib/database/domain_store.dart`

Opens the domain store (ADR-0035).

- **Native (`domain_store_io.dart`):** resolves the documents directory via `path_provider`, opens `jeeves_domain.sqlite` over `sqlite_async`, and reports whether the open created the file. It writes only names it owns and deletes nothing. Shared by Android, iOS, macOS, Linux and Windows, whose documents directories are *not* equally private — app-private on Android and iOS, the user's own folder on Linux and Windows — which is why nothing here may act on a file by name alone. A platform gaining divergent behaviour (an encryption key out of the Keychain, say) should split its own adapter rather than branching inside this one.
- **Web (`domain_store_stub.dart`):** throws `UnsupportedError`. Not a gap: the fleet is one Android phone, and a browser adapter would be an untested claim rather than a capability.

#### `app/lib/sync/sync_store.dart`

Opens the op-log store, `jeeves_sync.sqlite`, over Drift's native executor on a background
isolate. Same two-adapter shape, same reason for the stub.

#### `app/lib/services/platform_helper.dart`

Detects whether the app is running inside an Android emulator (for API host rewriting).

- **Native (`platform_helper_io.dart`):** reads `Platform.isAndroid` from `dart:io`.
- **Web (`platform_helper.dart` stub):** always returns `false`.

## Focus Mode Execution

Focus Mode is the task execution layer activated after daily planning. Its architecture separates ephemeral timer state from durable task state.

### Routing

`/focus/active` is a top-level `GoRoute` registered **outside** the `ShellRoute`, so `AppShell` (drawer, navigation) is not rendered. The user sees only the active task. `/focus` (the daily plan list) remains inside the `ShellRoute`.

The router's `redirect` callback does two things, and **both are negative: it turns users away from routes that cannot mean anything for their session, and never sends anyone into one.** It bounces `/register` to `/login` in SWS mode (the wallet is the identity, so there is no email signup), and it bounces `/enrolment` back to `/inbox` for the two sessions the ceremony has nothing to offer — signed out (no account to enrol against) and enrolled (already done, which is also how finishing the ceremony hands the user back to the app). Both fire only on a route the user had already navigated to. **Nothing routes a signed-in, un-enrolled device into `/enrolment`**: that session is redirected nowhere at all, because enrolment is opt-in, reached from Settings, and the app is fully usable without it (#673, [ADR-0046](./adr/0046-enrolment-is-opt-in-and-nothing-routes-to-it.md)). `refreshListenable: sessionGateNotifier` exists for the completed-ceremony bounce, so it does not wait for the next navigation.

`/focus` is unconditionally accessible from the drawer (entry labelled "Now" — the execution home's user-facing title; internal identifiers stay Focus, see CONTEXT.md); daily planning is entered explicitly via the "Plan the Day" button on the Focus screen or the amber `FocusSessionPlanningBanner` in `AppShell`. `/focus/active` is reached from the execution home's Start buttons and from the task detail screen's "Start focus" affordance, which engages the task with or without an open session (see `FocusModeNotifier`).

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

**An Outcome's text saves on focus loss** (ADR-0023), the same rule on all three surfaces that edit one — `TaskDetailScreen`, `ActiveFocusScreen`'s notes page and `ClarifyCard` on its Outcome shape — because editing an Outcome is ordinary editing. Energy, estimate and due date save immediately on the clarify shape.

**Each of the three also keeps a `dispose()` backstop**, so the save does not depend on the Navigator handing focus over. A route pop *does* notify the listener today — the newly-current route calls `setFirstFocus` while the popped subtree is still mounted — but that is framework behaviour the app does not own, and its failure mode is a silent, unlogged lost edit. The backstop writes only what differs from a per-field baseline (`TodoDao.updateFields` stamps `updated_at` and `last_clarified_at` and authors a sync op, so an unconditional flush would restamp clarification on every screen exit), fires and forgets with the failure logged, and — the #529 rule — never touches `ref`: `StatefulElement.unmount()` marks the element defunct before calling `state.dispose()`, so the writer (`GtdDatabase`, or the task-detail notifier) is captured in `initState` instead. Note the asymmetry: `State.mounted` is still **true** inside `dispose()`, because `state._element` is nulled afterwards, so a `mounted` guard is no protection there.

An emptied notes field travels as `clearNotes`, not as `''` (`null` reads as "no change" to the DAO, and every `notes == null` read treats an empty string as "has notes") — on `ActiveFocusScreen` and `ClarifyCard`. `TaskDetailScreen` still stores `''` on both of its exits, tracked as #705; its backstop deliberately inherits the focus-loss behaviour rather than fixing one exit and leaving the two disagreeing.

#### Live subject binding

All three surfaces bind to their subject live — `.forCapture` through `captureProvider`, `.forOutcome` through `taskDetailTodoProvider` — and reconcile on every emission rather than seeding once. Reconciliation is per field and respects local edits: a field whose content still matches its `_baseline*` marker (seeded from the row, adopted from a later emission, or written back to it) is *clean* and takes the incoming value; anything else is an edit in progress and is left untouched. A retained draft re-seeds through the same rule (`RetainedClarifyDraft.seedFrom`), carrying the baseline it was typed against — a dirty field keeps its **stale** baseline, which is what restores its dirty state so the live listener keeps leaving it alone for the card's life.

Every subject-bound surface — the clarify card and `TaskDetailScreen` — renders through `AsyncSubject`, the single-row counterpart to `AsyncList`. It splits the nullable subject into the four states it can actually be in, because `value == null` conflates two unrelated ones: *loading* (local storage has not answered) shows a spinner; *error* shows the shared `ErrorSurface`, never the raw exception; *missing* (`AsyncData(null)` — local storage answered, and there is no such row) shows the missing-item surface instead of the editable body, so a vanished item cannot be routed or written to; anything else is data. An error is checked before absence, so a failed query carrying a previously-null value is never mislabelled as a delete.

Missing is not only a render state. The predicate itself is `AsyncValue<T?>.subjectConfirmedMissing` (`async_subject.dart`), and a surface holding a *deferred* write latches it: `TaskDetailScreen` off its own `ref.watch`, `ActiveFocusScreen`'s notes page off a `ref.listen` on the same provider its parent watches. Their `dispose()` flush reads that latch and drops the write, so "cannot be written to" covers a write that was pending when the row went, not only one issued afterwards — without it the flush would land on a deleted row and author a sync op for a deleted entity. The latch is never cleared: un-latching on a row that reappears is live re-binding, which is out of scope (#427). It closes only the case where the surface *observed* the deletion; the window between the last emission and the flush needs a guard at the write seam (#444/#447), which is where these per-surface latches should eventually be replaced from. `AsyncList` and `AsyncSubject` render the same three non-data surfaces from `state_surfaces.dart`, so a list with no rows and a subject whose row is gone look identical — to the user they are the same thing. The missing surface carries a way out wherever the surface is its own route (`InboxClarifyScreen` → Back to Inbox, `TaskDetailScreen` → Go back), supplied through `missingCta`; the ceremony host passes none. All of this is reactivity to local storage and nothing more: a subject-bound surface reads a local row and has no way to tell a change made on this device from one replicated in, and does not try — which is also why the missing surface says the item is gone without claiming to know why.

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

`ClarifyCard` has two named constructors matching the ADR-0006 split: `.forCapture` (an Inbox Capture on its first pass) and `.forOutcome` (the re-clarify sub-flow). On a Capture the card unconditionally mirrors the live title into the draft's current-Action text (in `ClarifyDraft.assemble`), and `clarifyCaptureToOutcome` applies it as it mints the Outcome — a first clarification has no deliberate phrase to lose. Since issue #689 that mirror is the *proposal and the fallback* rather than the only path on the Next route: the Capture arm keeps the default-on `nextActionDialog` modifier, so Next opens the dialog seeded with the mirror and whatever the user saves overrides it (`_mergedAction`). Waiting For still routes straight through on the mirror alone. On an Outcome the mirror is guarded: the title is written only when the Outcome is Actionless (no `current` Action row), so a previously-written phrase is not clobbered by a re-clarification touch. The guard is **atomic** — the card makes a single `TodoDao.setCurrentActionTextIfActionless` call (issue #501), which performs the actionless check and the mirror write in one transaction; it replaced a read-then-write across two awaits, whose window a `current` Action landed by sync could slip through to be silently overwritten.

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
- `openSession(userId, taskIds)` — opens a new session with the given task list. Sessions never auto-close (ADR-0020): if one is already open, this **throws `StateError`** — the caller must have the user close it via Evening Shutdown first. This throw is the sole enforcement of the single-open-session invariant. A schema constraint would not be enough on its own: reduced state converges without consulting one, so two devices can each open a session offline and the invariant has to be repairable rather than merely declared.
- `watchQualifyingSessionExists(esAnchor)` / `qualifyingSessionExists(esAnchor)` — stream/one-shot for "does a session exist with `started_at >=` the most recent Evening Shutdown anchor" — the ES-anchor day-attribution predicate (ADR-0020).
- `closeSession(sessionId)` — closes the session and any open `TimeLog`.
- `setCurrentTask(sessionId, taskId?)` — atomically closes prior `TimeLog`, opens a new one for `taskId` (if non-null), updates `current_task_id`. The task need not be a Plan member — the Focus may point at any Outcome being engaged (off-Plan engagement, ADR-0005); the TimeLog still attributes to the session and the Plan never auto-grows.
- `watchActiveSession()` / `getActiveSession()` — stream/one-shot for the open session. Because the `openSession` throw is the *sole* enforcement of the single-open-session invariant, two open rows are a reachable state, so every read of "the" open session resolves them by one blessed rule rather than raising on them: `FocusSessionDao.openSessionWinnerFirstSql` — greatest `started_at`, tie-break smallest `id`, the newest intent winning, mirroring `ActionDao.winnerFirstOrderSql` for a multi-`current` set. It is the same split as `actions`: writers converge, reads only order — a reader that repaired would turn rendering the Focus surface into a sync-visible write, so the losing session is left for Evening Shutdown to close. The Plan and Review list queries (`watchActiveSessionTasks`, `watchActiveSessionReviewSurface`) join through the same rule, so they can never render one session's rows while the Focus surface names another, and `openSession`'s `StateError` names the winner — the session the user will actually be sent to close.
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
- `restore()` — silently restores a session from secure storage; returns `SessionRestoreOutcome`.

### AuthResult

`AuthResult` is the canonical return type for every provider sign-in:

```dart
class AuthResult {
  final String accessToken;
  final String refreshToken;
  final String userId;  // decoded from the JWT `sub` claim
}
```

`AuthNotifier` in `providers/auth_provider.dart` only deals with `AuthResult` and `SessionRestoreOutcome` — it never inspects JWT bytes itself.

### Session restore: three answers, and only one clears credentials

`restore()` returns a `SessionRestoreOutcome` (`auth/session_restore.dart`), not a nullable `AuthResult`, because "there is no session" and "I could not find out" must lead to different decisions:

| Outcome | Means |
|---|---|
| `SessionRestored` | A usable access token — stored and unexpired, or silently refreshed. |
| `SessionUnverified` | Credentials are on the device and were **not** authoritatively rejected. Carries the account id recovered from the stale token and the token itself. |
| `SessionAbsent` | Nothing stored, or the server authoritatively rejected what was. **The only outcome that clears credentials.** |

Both JWT-bearing providers (`PasswordAuthProvider`, `SwsAuthProvider`) delegate to the one `restoreJwtSession(AuthService)` rather than keeping a copy each, and `test/auth/session_restore_contract.dart` runs the same cases against both.

The verdict comes from `AuthService.refreshSession()`, which returns a sealed `SessionRefreshOutcome` — `SessionRefreshed`, `SessionRefreshRejected`, `SessionRefreshInconclusive`, `SessionRefreshTokenAbsent`. **Only a 401 corroborated as the Jeeves backend's own is `Rejected`**: corroboration is a JSON object body with a non-empty string `detail` (primary, because it is CORS-safe — the backend's `CORSMiddleware` exposes no headers, so the web build never sees them), falling back to a `WWW-Authenticate` header containing `Bearer`. Either is sufficient, and `detail` is matched on shape rather than text. A bare 401 from a captive portal, a 5xx, a timeout, a dead socket and a 200 full of garbage are all `Inconclusive`. See ADR-0041 for why the rule is stated as an inversion, and `backend/tests/test_sessions.py` for the producing side of that contract.

`AuthNotifier.build()` is an exhaustive switch over the three outcomes, and `clearTokens()` is reachable from exactly one arm:

| Situation | Credentials | `currentUserIdProvider` | `SessionGate` | Capture seam |
|---|---|---|---|---|
| Access token valid | retained | account | `ready` / `signedInNotEnrolled` | bound |
| Expired token, refresh **401 + corroboration** | **cleared** | `'local'` | `signedOut` | silent |
| Expired token, **bare 401** (captive portal / proxy) | **retained** | account | `ready` | **bound** |
| Expired token, server unreachable / 5xx / garbage | **retained** | account | `ready` / `signedInNotEnrolled` | **bound** |
| Inconclusive, and no account id recoverable from the stored token | cleared | `'local'` | `signedOut` | silent |
| No credentials stored | cleared (no-op) | `'local'` | `signedOut` | silent |
| User taps **Sign out**, offline | **cleared** | `'local'` | `signedOut` | silent |

The stakes are two-sided and both are tested. Clearing credentials resets the user to `'local'`, which makes `syncStackProvider` refuse and `syncLifecycleProvider` settle the capture seam silent — so on a device whose initial-upload marker is set, an over-eager clear drops the whole session's writes with nothing left to re-carry them. Retaining them too readily would leave a genuinely revoked device signed in. `test/sync/offline_relaunch_session_test.dart` holds both ends end-to-end; `test/providers/auth_notifier_restore_test.dart` holds the branch table at the session layer.

**`SessionGate` reports; it does not route.** `_enrolmentGate()` reads this device's own store with no network, and `signedInNotEnrolled` decides what Settings offers rather than where the user is (#673). It **fails open to `ready`** when the stack cannot be read — which is why every `SessionUnverified` case in `auth_notifier_restore_test.dart` reports `ready` regardless of enrolment, and why the un-enrolled combination is covered in `offline_relaunch_session_test.dart` instead, over a stack that assembles for real.

`SessionUnverified` returns the **expired** access token rather than null, so `authTokenProvider`'s value matches the `Authorization` header `AuthService.getToken()` has already set. Nothing reads that value for an authorisation decision, and keeping the two consistent means the first request once the network returns 401s into `_AuthRetryInterceptor` and the session self-heals.

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

**Query strategy:** A single Drift LEFT OUTER JOIN across `todos`, `todo_tags`, and `tags`. Drift's type-safe `readTable` / `readTableOrNull` API handles all column mapping so no manual SQL parsing is needed. Structured filters (state, energy level, time estimate, due date range) are applied as SQL WHERE clauses. Free-text search and tag-scope filtering are applied in Dart after the join.

**Why not FTS5?** LIKE + Dart-side string matching on 10k rows completes in < 10 ms in practice, and an FTS index would be a second thing the projector has to keep in step with reduced state. If the corpus outgrows the scan, the index becomes a projection concern rather than a trigger one — the projector is where reduced state lands, and triggers do not see it.

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

`syncedPreferencesProvider` (`lib/providers/synced_preferences_provider.dart`) is the single source of truth for all user-configurable settings that should survive across devices. It is an `AsyncNotifierProvider<SyncedPreferencesNotifier, SyncedPreferences>` backed by the `user_preferences` Drift table, which the op log carries in the User-global preferences Workspace.

### Storage model

All preference values are stored as JSON-encoded TEXT. A NULL value is a tombstone (treated as absent by `get`/`watch`). The `SyncedPreferences` value class provides a typed `get<T>(key)` accessor.

### Conflict resolution

Per-key conflict strategy is defined in `services/user_preferences_conflict.dart` — a `ConflictStrategy` registry (`lww` default, `maxTimestampValue` for snooze floors, `setMerge` provisioned for future list keys) with a pure `resolvePreferenceConflict` function. `strategyForKey` resolves in three steps: an exact entry in `preferenceConflictRegistry` wins, then the `snoozed_until` suffix rule, then the `lww` default. A key may register `lww` explicitly to record that its strategy was chosen rather than inherited (`clarify_mode` does). Deletion is a tombstone (present row, NULL value), never a physical removal — which is what makes "absent means nobody ever set it" true, so no rule can mistake a delete for a gap. On the op log the strategy is selected from the op alone (ADR-0033), and every strategy owes ADR-0030's lattice obligations. The full matrix lives in [SYNC.md](./SYNC.md).

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

`SyncedPreferencesNotifier.build()` subscribes to `dao.watchAll(userId)`. When the projector writes another device's reduced-in change to the local `user_preferences` table, the stream fires and the in-memory state updates automatically. Providers that derive state from preferences (e.g. `focusSettingsProvider`, `focusSessionPlanningSettingsProvider`, `clarifyModeProvider`) watch `syncedPreferencesProvider` via `ref.listen` and re-derive their state on each change.

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

**Live-refresh invariant (a write must notify what reads it):** Drift invalidates a stream query when a write reports rows on a table the query names in `readsFrom` — which covers a single-table write and nothing else. Two things fall outside it, and both are routine here: a write that changes one table while a live surface reads across several (an Action mutation moving a `todos`-backed list), and the projector's writes, which go through `customStatement` with no `updates:` set at all. The `SqliteAsyncDriftConnection` bridge names the table that actually changed and covers the simple case, but it is asynchronous and was observed briefly silent on a cold start (#342). Every `TodoDao` method that writes `todos` directly therefore calls `GtdDatabase.notifyTodosViewWrite(...)` immediately after the write (`applyRouting`, `setCurrentActionText`, `setCurrentActionTextIfActionless` (only on its write path — the skip path notifies nothing), `rescheduleTask`, `stampLastClarifiedAt`, `setPersonTagsAndStamp`, `updateFields`, and the `delete`-based `deleteOutcome`) to give Drift a second, in-process invalidation path, so the `todos`-backed lists — Next Actions, Waiting For, Someday/Maybe and the review surfaces — refresh without an app restart. The Inbox list and its badge are `captures`-backed (`CaptureDao.watchInbox` / `watchInboxCount`) and get the same guarantee from the `notifyCapturesViewWrite` analogue, which notifies all three Capture tables as one group because the Inbox reads across them. The helper emits kind-less `TableUpdate`s, so a single call serves updates and deletes alike. Only `update` / `delete` need it: `into(todos).insert(...)` and `customUpdate` / `customInsert` notify unconditionally, so captures and DAO methods built on them (`markDone`, `setIntent`, …) already satisfy the invariant. Any new method that writes one of these tables directly with `update`/`delete` must add the same call. `actions` is under the same discipline: `ActionDao` calls `GtdDatabase.notifyActionsViewWrite()` after every write, and the `TodoDao` methods that touch both grains in one transaction (`setCurrentActionText`, `setCurrentActionTextIfActionless`, `applyRouting`, `deleteOutcome`) notify both the `todos` and `actions` views after it commits. `completeCurrentAction` notifies both too, despite writing nothing to `todos` at all — the cursor is retired (ADR-0022), so there is no `todos` write left to gate the notify on. It still fires because the Outcome's own list membership changes when its Action completes, and two list watchers name only `{todoTags, tags}` in `readsFrom`, so an `actions`-only notification would never reach them; the notify rides on `ActionWriteEffect.changed` rather than `stamped`, which is always false for completion.

### `ProcessToHandlers` — the canonical "process to" action bar

`ProcessToHandlers` (`app/lib/widgets/process_to_handlers.dart`) is the single widget rendered wherever the user commits a routing verdict — against either shape of the ADR-0006 split, an Outcome (`OutcomeSubject`) or a Capture (`CaptureSubject`). Its surfaces: the standalone `InboxClarifyScreen`, the inbox-clarify card (planning Step 0 and weekly review's zero-inbox step), the daily planning task-review step, and the weekly review's Waiting For / Next Actions / Someday-Maybe steps.

The widget owns its writes, delegated to `ClarificationService`. Callsites speak `ProcessAction` (`keep`, `reclarify`, `next`, `waitingFor`, `someday`, `done`, `trash`, plus the `nextActionDialog` modifier on `next`) and never see `RoutingKind`. Callsites that hold a `RoutingKind` from a session record translate at the read site via the co-located `RoutingKind.toProcessAction()` extension. `keep` and `reclarify` have no `RoutingKind` equivalent (`keep` stamps `last_clarified_at` only; `reclarify` opens a sub-flow whose result bubbles back as the chosen routing action).

The `nextActionDialog` modifier is **on by default** — promoting a Todo to Next always opens `NextActionDialog` to capture a phrase, so a freshly-promoted task lands on the Next list with a defined action rather than re-surfacing in the daily re-clarification queue. A phrase is invited rather than demanded, so it does not strand the user on a titled item: saving the dialog empty applies the **title-as-action fallback** (ADR-0049) and resolves the item like any other save. A **blank-titled** Outcome is the one case that still stalls — there is nothing left to stand in as the Action (see the modifier's sub-flow below). The opt-out is no longer universal on the clarify surfaces: `ClarifyCard` excepts it **only on its Outcome arm** (`if (!_isCapture)`), where the title-as-action coupling supplies the phrase and Next is a one-tap route. On a Capture — both the 1-1 card and the n-m carve in `CaptureOutcomesSection` — the modifier stays on (issue #689), because the Outcome and its Action are distinct and "car insurance renewal" names a desired outcome rather than a physical next step. The Next Actions weekly-review step also excepts it (it has no Next button at all).

API:

- `include: Set<ProcessAction>` — surface non-default actions (e.g. `keep`). The `nextActionDialog` modifier is default-on, so it is removed via `except`, not added via `include`.
- `except: Set<ProcessAction>` — hide default actions and the default-on `nextActionDialog` modifier (e.g. the Waiting For step uses `except: {waitingFor}` because the user is already on a waiting item, Keep covers re-confirmation; the re-clarify card uses `except: {nextActionDialog}` to keep Next as a one-tap route on an Outcome, and the Capture arm of the same card deliberately does not).
- `disabled: Set<ProcessAction>` — render disabled-state but still draw the button (parent-owned validation, e.g. inbox card disables routes while the title is empty).
- `labels: Map<ProcessAction, String>` — per-callsite label overrides, applied over the subject-resolved defaults. Use sparingly: the defaults are the canonical vocabulary and the widget exists to collapse the pre-extraction drift.

Labels are resolved from the subject, not fixed per action. `trash` is the one action whose canonical name differs by shape: on an `OutcomeSubject` it is **Trash** (`Intent = trash`, landing the row on the Trash List), on a `CaptureSubject` it is **Discard** — the zero-Outcome verdict creates nothing, so the item never reaches that List and "Trash" would name a destination it never arrives at. Because the resolution lives in the widget, the copy cannot drift between clarify surfaces.

The widget owns the tap handler, so no callsite can catch failures itself — it therefore reports them, behind **two separate error boundaries**:

- A **routing write** that throws is caught and reported as "Operation failed. Please try again."; `onAfterRoute` is not called, so a failed write never advances a cursor or records a routing.
- A throwing **`onAfterRoute` hook** is caught separately and reported as "Saved, but finishing up failed…". The write has already landed by then, so reusing the retry copy would invite the user to redo a route that actually succeeded.
- `lastAction: ProcessAction?` — drives the "previously selected" affordance on the matching button when the user backs up to revisit an item.
- `onAfterRoute: (ProcessAction) -> Future<void>` — fires once after the action settles without error (after `keep` stamps `last_clarified_at`, and after a route commits). Used for callsite-specific bookkeeping (advancing a snapshot cursor, recording the routing for the highlight) and for callsite-owned writes on the user-action axis — e.g. on its **Outcome** shape `ClarifyCard` mirrors the live title into the current Action here when the user routes to Next/Waiting For (title-as-action coupling, Actionless-guarded). On a **Capture** there is no such write: the mirror travels in the draft and `clarifyCaptureToOutcome` applies it as it mints the Outcome. Not called when the user cancels a sub-dialog, and not called when the write throws.

  Whenever it fires for `nextActionDialog`, a route **has** landed: an empty save falls back to the Outcome's title rather than skipping the write, and the one arm that writes nothing — an empty phrase over a blank title — returns without firing the hook at all. Callsite handlers are correspondingly unconditional; those that want the phrase for their in-session record still read it back from `actions`, because the fallback means the stored phrase is not the string the dialog returned.
- `onProcessingChanged: (bool) -> void` — mirrors the bar's in-flight state out to the callsite, for surfaces that render their own affordances beside it. `ClarifyCard` forwards it to its own host; `InboxClarifyScreen` uses it to shut Skip, the app-bar back arrow, the pinned capture action and its `PopScope` during a write, so the verdict cannot land against a screen the user has already left.

Sub-flows owned by the widget:
- The Waiting For button opens `PersonTagPickerSheet`, which **pops with the chosen person-tag ids** (`null` on cancel) rather than writing them itself. The widget awaits that result and, only once the sheet has closed and the subject is confirmed to still exist, commits intent + delegate in a single routing write — `clarifyToOutcome` replaces the person-tag set atomically on an Outcome, `clarifyCaptureToOutcome` attaches it to the Outcome it mints. Cancelling writes nothing and fires no hook. The current Action is on the orthogonal user-action axis and is left alone.
- The `nextActionDialog` modifier opens `NextActionDialog` (`app/lib/widgets/next_action_dialog.dart`) prefilled, and writes the new phrase on save — this is the only widget-internal path that mutates the user-action axis. The prefill is **per subject**: on an `OutcomeSubject` it is the current Action's text, supplied by the callsite as `currentActionText` from the snapshot of `actions` it already loaded; on a `CaptureSubject` there is no Outcome yet to carry one (`currentActionText` is null by contract), so the seed is the draft's own Action — `ClarifyDraft.assemble`'s title mirror — read at dialog-open time through the `draft` callback. The dialog's heading is likewise asked of the subject rather than inferred from the prefill (`editingExistingAction`): a Capture's seeded field is a proposal for an Action that does not exist yet, so it reads "Set next action", never "Update". Because the modifier is default-on, this is the standard Next behaviour everywhere except the callsites that `except` it. Promoting a delegated Waiting For item to Next keeps its person tags (intent ⊥ delegate) — `applyRouting` only touches the delegate axis when `personTagIds` is passed.

  **Cancel and an empty save are different acts**, kept apart by the dialog's return *type*: cancel (button, barrier tap, system back) resolves to `null`, an empty save to `''`. `null` is the only *result* that returns before any write and before the hook, so cancel is the only dialog outcome that leaves the item unresolved; the one other unresolved case turns on the *subject* rather than the result — a blank-titled Outcome, below. Collapsing the two — `result?.isEmpty ?? true`, or having the dialog pop the title on an empty save — silently breaks that contract while every other behaviour stays green, so both are pinned by separate tests.

  An empty save applies the **title-as-action fallback** (ADR-0049): it routes with no `actionText` (a *non-null* blank would supersede the current Action, #476), then, on an `OutcomeSubject`, writes the Outcome's title as its current Action through `ClarificationService.mirrorTitleIfActionless` — Actionless-guarded, so a deliberate phrase is never clobbered, and atomic, so a `current` Action landed by sync between the check and the write cannot be either (#501). A `CaptureSubject` needs no such step: `_mergedAction` keeps the draft's own Action, which already carries `ClarifyDraft.assemble`'s title mirror, and it is written as the Outcome is minted. The one arm that still stalls is an empty phrase over a **blank title** — nothing can stand in as the Action, and routing would leave the row on Next while Actionless, which `TodoDao._needsReviewWhere`'s ungated Actionless branch would re-surface on the identical review card forever.
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

**Terminal-transition hook.** When an Action reaches a terminal state with an open log attributed to it, `ActionDao` closes that log at the transition timestamp: `applyCompleteCurrentAction` (Done) and `applySupersedeCurrentAction` (supersede/clear) both close it. A supersede *with a replacement* also **reopens** a continuation log against the successor Action (copying `task_id`, `user_id`, and `focus_session_id`, `started_at = ts`), so switching Actions closes the current TimeLog and opens a new one with zero seconds lost (CONTEXT.md § Switching Actions). `applySupersedeAndPromote` — the planned-queue "Replace current action" gesture — is the same transition and reopens the continuation against the promoted planned row. An in-place text/metadata edit keeps the same Action id, so the open log is untouched. Done closes at the Action's completion rather than at a later `endFocus()` — deliberate: engagement on a finished Action ends at Done. The active-log and time-spent watchers do not name `actions`, so every path that closes or reopens a log fires `notifyTimeLogsViewWrite` after commit (gated on `ActionWriteEffect.logChanged`) — ADR-0010.

Time spent on an Outcome is a derivation, never a stored value: `SUM(time_logs)` at read time, with per-interval minutes ceiling-rounded and open rows counting up to the current time. There is no `todos` column for it — a stored total would be a cache that can only ever go stale (ADR-0030), so the read paths compute it and no `Todo` carries it. The derivations, all sharing one arithmetic spelling (`TimeLogDao` keeps a private `_stintMinutesCeilSql` fragment): the ceiling is exact integer-millisecond division (`unixepoch(…, 'subsec')`, then `(ms + 59999) / 60000`), never floating-point — `julianday()`'s days-since-4714-BC magnitude carries tens of microseconds of double error either way, so any ceiling over that float inflates about half of all whole-minute stints by a minute, and the `+ 0.9999` epsilon that used to mask it swallowed genuine remainders under 6ms (issue #615). A `MAX(0, …)` clamp values a clock-skewed row (`ended_at` before `started_at`) at zero rather than letting a negative summand reduce the total. The derivations:

- `TimeLogDao.totalMinutesForTask` — one Outcome, one shot (e.g. the sprint number on `startSprint`).
- `TimeLogDao.watchTotalMinutesByTask` — minutes per Outcome, keyed by `task_id`, re-emitted on any log write. The Evening Shutdown Review steps watch it (via `loggedMinutesByOutcomeProvider`) beside the Review surface, and `OutcomePeekSheet` reads the single-task form. An Outcome with no stints is absent from the map, read as `0`.
- `TimeLogDao.totalMinutesSubquery` — the correlated subquery embedded in list queries that need the total inline.

These totals are **task-grain** — they aggregate by `task_id` and so count legacy (`action_id IS NULL`) and Action-attributed rows identically. Per-Action time-spent reads exist alongside them for history: `TimeLogDao.totalMinutesSubqueryForAction` (story 8, issue #478) aggregates by `action_id` instead, and is what `ActionDao.watchTerminatedActions` / `getTerminatedActions` join in per terminated row (see the `actions` data-model note above).

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
