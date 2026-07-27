# ADR-0024: Drop the retired next-action cursor

**Status:** Accepted
**Date:** 2026-07-27
**Context:** Issue #525, epic #470. Reverses ADR-0022. Builds on ADR-0012 (clarification-neutral sweep), ADR-0015 (upsert-on-replay), ADR-0017 (sync-rules-as-config), ADR-0018 (supersession without linkage), ADR-0019 (deterministic dual-origin backfill ids).

## Decision

`todos.next_action_text` is **dropped from the client and from Postgres in one change**. ADR-0022 retired it by abandonment and argued explicitly against a drop; this reverses that. On the client the column leaves `tables.dart`, the generated PowerSync schema, `TodoDao.todoProjectionSql`, and the Drift v26 backfill that was its last consumer, with a `from < 28` migration dropping it from any real table. On the server Alembic 0030 drops it together with the SQLAlchemy column, all three Pydantic schemas and the route kwarg. The two one-field `TodoDao` surfaces are renamed off the cursor's name onto the Action's (`setNextActionText` → `setCurrentActionText`), so nothing in the Dart API outlives the column.

Splitting this into a client change and a later backend change would only have bought the ability to sequence devices across the boundary. The owner's ruling is that no dependent device exists, which voids that purchase and leaves the standing principle: a schema change and the code that depends on it ship together.

ADR-0022 stands as the record of why abandonment was right at the time. It is not amended; this ADR supersedes its conclusion.

## Why ADR-0022's three grounds no longer hold

**"The v26 backfill is guarded on the cursor columns' presence."** That guard was load-bearing only while the client-side backfill was the recovery path for a store that predated the `actions` table. Alembic 0028 performs the same backfill **server-side**, minting the same uuid5 from the same derived fields — server and client backfills were designed to converge on a single row (ADR-0019, ADR-0015). The server therefore already holds every Action the client backfill would mint, and a client reaching v26 today re-syncs them rather than re-deriving them. Deleting the backfill and the column **in the same change** makes the silent-skip failure ADR-0022 feared impossible by construction, rather than adding a fourth guard. That is the same move-shape ADR-0022 itself chose when it deleted cursor adoption outright instead of guarding it tighter.

**"Unschedulable — ADR-0017's pipeline cannot express rules-before-migration."** Does not apply. The bucket is `SELECT * FROM todos WHERE user_id = bucket.user_id`, so no sync rule names the column; `sync-config.yaml` is unchanged, `publish-sync-config.sh` will report "sync config unchanged", and PowerSync never restarts. The expand/contract table collapses to its trivial rows.

**"Columns cost nothing."** True of storage, false of reasoning. A declared column is something every future contributor must re-derive the retirement story for, and roughly twenty test files that seed it are tests whose subject is ambiguous — the tests that seeded a cursor to prove the sweep ignored it read as coverage of the cursor rather than of the invariant. Removing the column removes the ambiguity.

What replaced ADR-0022's "blocked on a demonstrated cost" trigger is not a cost. It is the **window**. A controlled alpha fleet is the cheapest possible moment to discover that a schema removal breaks something; the fleet only grows and the window only narrows.

## What the drop actually reaches, and the risk taken on

ADR-0022 reasoned that a server-side drop would make the column vanish from every client at once. It does not: **PowerSync does not replicate DDL.** Rows already in bucket storage keep their value, and the column decays row-by-row as each row is next updated. A post-#479 client is therefore unaffected — `Todo.nextActionText` silently goes null, nothing reads it, and its uploads still 201 because Pydantic's default `extra='ignore'` drops the retired field.

The build that would be harmed is one predating **#479**. Its startup sweep still carries Pass B: it retires every `current` Action whose Outcome has a blank cursor. As the cursor decays to NULL that build destroys the Action grain on the device **and syncs the deletions to every other device.** Wiping the offending device does not repair it — the damage has already replicated. ADR-0022 § Version skew already recorded that those binaries are unreachable by release ordering, which is the point: **no ordering of this change could have made such a device safe.** The drop therefore ships on the owner's ruling that none exists, and the hazard is recorded here as a risk accepted inside the alpha window rather than as a gate on the change.

Atomicity *within* the change is not a matter of ruling. Dropping the column while `routes.py` still passed `next_action_text=` to the `Todo(...)` constructor would 500 every todo POST; PowerSync classifies 5xx as retryable, so the upload queue would wedge permanently on every device. The Alembic migration, the mapped column, the three Pydantic schemas and the route move in one commit for that reason — a hazard internal to the change, independent of any assumption about clients.

## Recovery, and what is intentionally discarded

**Recovery is wipe-and-reseed.** The server holds the Actions; a wiped client re-syncs correct data. The accepted cost is local-only unsynced state on the wiped device.

Two things are deliberately discarded. First, the Postgres `next_action_text` values — Alembic 0028 already derived every non-blank one **that existed when it ran** into an `actions` row, so what is lost is duplicated text, not information. 0028 is a one-time migration with no successor pass, so that guarantee stops at rows written after it; nothing has written the cursor since #479, which leaves only a pre-#479 client as a source of uncovered text, and the ruling above is that none exists. Second, the cursor text on a **never-signed-in, pre-Drift-v26** local store, which has no server copy and nothing to reseed from. That second case is the only genuinely unrecoverable one, and it is not being waived as negligible: it is an **explicit exception taken inside the alpha window**, on the owner's ruling, on a fleet the owner controls. The general question it raises — what durability guarantee an offline-first client owes a store that has never synced — is **not settled by this ADR** and is tracked in **#534**.

## On deleting `action_cursor_freeze_test.dart`

That suite's subject was "no code path writes `todos.next_action_text`", asserted by seeding a sentinel and checking it survived every primitive. **A column that does not exist is strictly stronger than a test asserting nothing writes it**, so deleting the suite is a strengthening, not a coverage loss. The line is held instead by a schema-absence assertion in `powersync_schema_consistency_test.dart`, which fails if the column returns to the Drift schema, the generated PowerSync schema, or the created table — the single test that fires if someone re-adds it "for old-client compatibility". Two of the suite's tests turned out to carry unique Action-grain coverage rather than cursor coverage (`setCurrentActionTextIfActionless`, including #501's TOCTOU skip path, and `deleteOutcome`'s cascade onto `actions`); those moved to `todo_dao_test.dart` rather than being deleted with the file.

The structural anchor for the sweep survives untouched: `reconcile_actions_sweep_test.dart` still drives the pass against a store that has **no `todos` table at all**, so any re-introduced Outcome-column read raises `no such table` rather than quietly destroying Action rows.

## On AGENTS.md § Data Persistence

That rule says never write a destructive migration. This is a deliberate, owner-authorised exception, scoped to **one column whose information content is already duplicated into `actions`**, taken inside the alpha window on a fleet of known devices. It does not weaken the rule, and it is not a precedent: **no second exception should cite this one without its own ADR** making its own case on its own facts.
