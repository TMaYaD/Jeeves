"""Split captures out of the conflated todos table (ADR-0006).

Revision ID: 0026
Revises: 0025
Create Date: 2026-07-17

The Inbox has always been modelled as ``todos WHERE clarified = false`` — a
capture is a raw thought, not yet a task.  ADR-0006 splits that concept into
its own table so Capture and Outcome (todo) are distinct entities.  This
migration:

- Creates ``captures`` (owned-entity, mirrors todos' capture columns; the
  Inbox marker becomes ``clarified_at IS NULL``).
- Creates the ``capture_outcomes`` junction (Capture → Outcome/todo) carrying
  a client-owned ``created_at`` provenance timestamp.
- Creates the ``capture_tags`` junction (Capture → Tag), mirroring todo_tags.
- Moves every ``clarified = false`` todo (and its tag links) into
  ``captures`` / ``capture_tags``, then deletes those rows from ``todos``
  (their todo_tags cascade away via the existing FK).
- Adds all three tables to the powersync publication.

This is a NON-ADDITIVE data-move migration.  Per ADR-0012 the data move runs
without idempotency guards and fails loud — re-running it after a partial
apply is a stamp/repair problem, not something to paper over silently.

``todos.clarified`` and ``todos.capture_source`` are deliberately retained:
dropping them is deferred (capture_source is not uniform on existing
Outcomes, so dropping it would lose data).

Downgrade note: this migration is IRREVERSIBLE.  The moved rows cannot be
reconstructed back into ``todos`` (the original clarified=false rows were
deleted), so ``downgrade()`` refuses to run — it raises before touching any
schema rather than silently dropping every Capture the user has created.
Recovery from a bad forward apply is a restore from backup, not a downgrade.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0026"
down_revision: str | None = "0025"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ── 1. captures (owned-entity) ──────────────────────────────────────────
    op.create_table(
        "captures",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("title", sa.String(500), nullable=False),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("capture_source", sa.String(50), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column("clarified_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "user_id",
            sa.String(),
            sa.ForeignKey("users.id"),
            nullable=False,
        ),
    )
    op.create_index("ix_captures_user_id", "captures", ["user_id"])

    # ── 2. capture_outcomes (junction with client-owned created_at) ─────────
    op.create_table(
        "capture_outcomes",
        sa.Column(
            "id",
            sa.String(),
            nullable=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "capture_id",
            sa.String(),
            sa.ForeignKey("captures.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "outcome_id",
            sa.String(),
            sa.ForeignKey("todos.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.text("now()"),
        ),
        sa.Column(
            "user_id",
            sa.String(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
    )
    op.create_index("ix_capture_outcomes_id", "capture_outcomes", ["id"], unique=True)
    op.create_index("ix_capture_outcomes_user_id", "capture_outcomes", ["user_id"])

    # ── 3. capture_tags (junction, mirrors todo_tags) ───────────────────────
    op.create_table(
        "capture_tags",
        sa.Column(
            "id",
            sa.String(),
            nullable=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "capture_id",
            sa.String(),
            sa.ForeignKey("captures.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "tag_id",
            sa.String(),
            sa.ForeignKey("tags.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "user_id",
            sa.String(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
    )
    op.create_index("ix_capture_tags_id", "capture_tags", ["id"], unique=True)
    op.create_index("ix_capture_tags_user_id", "capture_tags", ["user_id"])

    # ── 4. Move the Inbox rows (NO guard — fail loud, ADR-0012) ─────────────
    # clarified_at stays NULL (they are unclarified — in the Inbox) and
    # updated_at stays NULL.  created_at carries over verbatim.
    op.execute(
        "INSERT INTO captures (id, title, notes, capture_source, created_at, user_id) "
        "SELECT id, title, notes, capture_source, created_at, user_id "
        "FROM todos WHERE clarified = false"
    )

    # ── 5. Copy the tag links for the migrated rows ─────────────────────────
    op.execute(
        "INSERT INTO capture_tags (id, capture_id, tag_id, user_id) "
        "SELECT gen_random_uuid(), tt.todo_id, tt.tag_id, tt.user_id "
        "FROM todo_tags tt "
        "WHERE tt.todo_id IN (SELECT id FROM todos WHERE clarified = false)"
    )

    # ── 6. Delete the moved todos (their todo_tags cascade via existing FK) ─
    op.execute("DELETE FROM todos WHERE clarified = false")

    # ── 7. Replicate the new tables to clients ──────────────────────────────
    op.execute("ALTER PUBLICATION powersync ADD TABLE captures")
    op.execute("ALTER PUBLICATION powersync ADD TABLE capture_outcomes")
    op.execute("ALTER PUBLICATION powersync ADD TABLE capture_tags")


def downgrade() -> None:
    # This migration is irreversible: upgrade() moved the Inbox rows out of
    # ``todos`` and dropped the originals, so a downgrade cannot reconstruct
    # them — dropping the three tables here would silently destroy every
    # Capture (and its clarification provenance) the user created since.  Fail
    # loudly BEFORE touching any schema or data rather than pretend to roll
    # back.  Recovery from a bad forward apply is a restore-from-backup +
    # ``alembic stamp`` decision (see the module docstring), not a downgrade.
    raise RuntimeError(
        "Migration 0026 (split_captures_from_todos) is irreversible: the "
        "Capture split moved and deleted the old clarified=false todos rows, "
        "so downgrading would destroy all Capture data with no way to rebuild "
        "the originals. Restore from a backup and `alembic stamp` the target "
        "revision instead of running `alembic downgrade`."
    )
