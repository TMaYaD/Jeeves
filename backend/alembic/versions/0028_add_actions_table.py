"""Add the actions table + backfill a current Action per Outcome (issue #471).

Revision ID: 0028
Revises: 0027
Create Date: 2026-07-24

ADR-0001 story 1: the Actions storage exists and replicates everywhere before
any read/write path depends on it (epic #470).  This migration is **additive**
— nothing is moved or deleted — and every step below is individually guarded,
so re-entering it never duplicates or overwrites:

Re-runnability is bounded, and no longer general.  The backfill in step 2 reads
``todos.next_action_text``, which **0030 drops** (issue #525, ADR-0024).  So
0028 is re-runnable only while that column still exists — i.e. within a single
0027 → head run, where 0028 precedes 0030.  Once the chain has reached 0030,
rewinding ``alembic_version`` and re-entering 0028 raises
``UndefinedColumnError`` rather than no-opping, so it is **not** available as
the ADR-0012 drift-recovery move (which is in any case a deliberate human
``alembic stamp``, never an automatic one).  ADR-0024 makes this a one-time
migration with no successor pass: rows written after it are not covered, and
nothing has written the cursor since #479.  The ordering constraint is pinned
by ``test_0028_backfill_reapplied_over_existing_rows_is_a_no_op`` in
``backend/tests/test_migration_chain_postgres.py``, which re-enters the
backfill at 0028 — before 0030 — for exactly this reason.

The guards themselves:

1. Schema (guarded): create ``actions`` when it does not already exist
   (``inspector.has_table`` — 0024/ADR-0012 discipline).  ``ix_actions_user_id``
   / ``ix_actions_outcome_id`` are then checked **independently** of the table
   guard (against ``get_indexes``), so a store where the table exists but an
   index was never created — a partially-applied forward run — still gets the
   missing index on re-run.  The ``ALTER PUBLICATION`` step likewise gets its
   **own** guard against ``pg_publication_tables`` rather than piggybacking on
   ``has_table``, so a drifted store where the table exists but was never
   published still gets published on re-run.

2. Backfill (data, idempotent): one ``current`` Action for every Outcome whose
   ``next_action_text`` is non-blank (the whitespace-only normalisation in the
   app's ``todo_dao.dart`` — blank means Actionless, mint nothing).  The id is
   ``uuid5(NAMESPACE_URL, "jeeves://action/backfill/<todo_id>")`` computed in
   Python (Postgres has no builtin uuid5; row counts are user-scale) so the
   server backfill and the client-side Drift v26 backfill mint the **same** row
   and ADR-0015 upsert-on-replay collapses the duplicate upload (ADR-0019).
   Every field derives only from replicated Outcome data —
   ``created_at = COALESCE(last_clarified_at, created_at)`` — so the two origins
   produce field-identical rows, not just id-identical ones.  Each insert is
   guarded by ``ON CONFLICT (id) DO NOTHING``, so a re-run, or a run after
   clients already uploaded their own backfill rows, is a no-op that never
   overwrites.

No partial unique index on ``(outcome_id) WHERE role = 'current'`` ships: a
unique violation would be a 500 → infinite connector retry, and catching it to
4xx would dead-letter a legitimate replay (SYNC.md window 3 / ADR-0015 forbid
it).  Deterministic ids make a second current row per Outcome impossible here
anyway; the 0..1-current invariant is application-enforced from story 2 on.

Downgrade note: IRREVERSIBLE.  Dropping ``actions`` would destroy every Action
row minted since — including ones clients uploaded — so ``downgrade()`` refuses
to run rather than silently lose data (0026 precedent).  Recovery from a bad
forward apply is a restore-from-backup + ``alembic stamp``, not a downgrade.
"""

import uuid
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0028"
down_revision: str | None = "0027"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def _backfill_action_id_for(todo_id: str) -> str:
    """Deterministic Action id for an Outcome's backfilled current Action.

    Must stay byte-identical to the Dart ``backfillActionIdFor`` (see
    app/lib/database/daos/action_ids.dart) — both are RFC-4122 URL-namespace
    uuid5, both lowercase — so server and client backfills converge on one row
    (ADR-0019).  A shared golden vector pins the cross-language equality.
    """
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"jeeves://action/backfill/{todo_id}"))


def upgrade() -> None:
    bind = op.get_bind()
    inspector = sa.inspect(bind)

    # ``now()`` is Postgres SQL; SQLite (the migration test harness) would
    # reject the bare-function DEFAULT at CREATE TABLE time, so omit it there.
    # The backfill always supplies created_at explicitly, and route inserts get
    # the Python-side model default, so no-default-on-SQLite is harmless.
    created_at_default = sa.text("now()") if bind.dialect.name == "postgresql" else None

    # ── 1. Schema (additive, guarded so a re-run no-ops) ────────────────────
    if not inspector.has_table("actions"):
        op.create_table(
            "actions",
            sa.Column("id", sa.String(), primary_key=True),
            sa.Column(
                "outcome_id",
                sa.String(),
                sa.ForeignKey("todos.id", ondelete="CASCADE"),
                nullable=False,
            ),
            sa.Column(
                "user_id",
                sa.String(),
                sa.ForeignKey("users.id"),
                nullable=False,
            ),
            sa.Column("text", sa.Text(), nullable=False),
            sa.Column("role", sa.String(20), nullable=False),
            sa.Column("position", sa.Integer(), nullable=True),
            sa.Column("energy_level", sa.String(20), nullable=True),
            sa.Column("time_estimate", sa.Integer(), nullable=True),
            sa.Column(
                "created_at",
                sa.DateTime(timezone=True),
                nullable=False,
                server_default=created_at_default,
            ),
            sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
            sa.Column("done_at", sa.DateTime(timezone=True), nullable=True),
        )

    # Indexes are checked independently of the table guard: a drifted store
    # where `actions` exists but an index was never created (a partially-applied
    # forward run) still gets repaired on re-run, honouring the migration's
    # re-runnable recovery contract (ADR-0012). Each is created only when absent
    # so a clean re-run is a no-op.
    existing_indexes = {index["name"] for index in sa.inspect(bind).get_indexes("actions")}
    if "ix_actions_user_id" not in existing_indexes:
        op.create_index("ix_actions_user_id", "actions", ["user_id"])
    if "ix_actions_outcome_id" not in existing_indexes:
        op.create_index("ix_actions_outcome_id", "actions", ["outcome_id"])

    # ── 2. Replicate to clients (Postgres only; independent publication guard) ─
    # Guarded on pg_publication_tables rather than has_table so a store whose
    # table exists but was never published still gets published on re-run.
    if bind.dialect.name == "postgresql":
        op.execute(
            """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync')
     AND NOT EXISTS (
       SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'powersync' AND tablename = 'actions'
     ) THEN
    ALTER PUBLICATION powersync ADD TABLE actions;
  END IF;
END $$;
"""
        )

    # ── 3. Backfill one current Action per non-blank-cursor Outcome ─────────
    # Predicate mirrors the app's actionless normalisation: a NULL or
    # whitespace-only next_action_text is Actionless — mint nothing.
    qualifying = bind.execute(
        sa.text(
            "SELECT id, next_action_text, energy_level, time_estimate, "
            "last_clarified_at, created_at, user_id "
            "FROM todos "
            "WHERE next_action_text IS NOT NULL AND TRIM(next_action_text) != ''"
        )
    ).all()

    # The re-run guard is ``ON CONFLICT DO NOTHING`` on the primary key rather
    # than ``WHERE NOT EXISTS (... WHERE id = :id)``.  The latter bound ``:id``
    # twice — once as a bare value in an INSERT..SELECT list, where Postgres
    # deduces ``text``, and once against ``actions.id``, where it deduces
    # ``character varying`` — and asyncpg's prepared statements make the
    # disagreement fatal: ``AmbiguousParameterError: inconsistent types deduced
    # for parameter $1``.  It fired only when the backfill loop had at least one
    # row to insert, so an empty database never prepared the statement at all.
    # Binding the id exactly once, in a VALUES list whose target column types
    # are known, makes the deduction unambiguous by construction — a cast that
    # merely reconciled the two positions would leave the next edit free to
    # reintroduce the same class of failure.  The guard's semantics are
    # unchanged: a re-run, or a run after clients uploaded their own backfill
    # rows, is a no-op that never overwrites.
    insert_stmt = sa.text(
        "INSERT INTO actions "
        "(id, outcome_id, user_id, text, role, position, energy_level, "
        " time_estimate, created_at, updated_at, done_at) "
        "VALUES (:id, :outcome_id, :user_id, :text, 'current', NULL, "
        "        :energy_level, :time_estimate, :created_at, NULL, NULL) "
        "ON CONFLICT (id) DO NOTHING"
    )

    for row in qualifying:
        # created_at derives only from replicated data (deterministic across
        # origins): the cursor-set proxy is last_clarified_at, falling back to
        # the Outcome's created_at.  ADR-0019 notes this is an upper bound.
        created_at = row.last_clarified_at if row.last_clarified_at is not None else row.created_at
        bind.execute(
            insert_stmt,
            {
                "id": _backfill_action_id_for(row.id),
                "outcome_id": row.id,
                "user_id": row.user_id,
                "text": row.next_action_text,  # verbatim, no trim
                "energy_level": row.energy_level,
                "time_estimate": row.time_estimate,
                "created_at": created_at,
            },
        )


def downgrade() -> None:
    # Irreversible: dropping ``actions`` destroys every Action row minted since
    # (server backfill + client uploads), with no way to reconstruct the ones
    # clients edited.  Fail loudly BEFORE touching any schema rather than
    # silently lose data.  Recovery is a restore-from-backup + ``alembic stamp``
    # (see the module docstring), not a downgrade.
    raise RuntimeError(
        "Migration 0028 (add_actions_table) is irreversible: dropping the "
        "actions table would destroy every backfilled and client-uploaded "
        "Action row with no way to rebuild them. Restore from a backup and "
        "`alembic stamp` the target revision instead of running "
        "`alembic downgrade`."
    )
