"""Collapse 'scheduled' state into 'next_action'; shrink GTD_STATES CHECK.

Revision ID: 0011
Revises: 0010
Create Date: 2026-04-27

'scheduled' carried no behavior beyond a separate list view (no auto-transition
on the date, no notification).  All rows are moved to 'next_action' with
due_date preserved — due_date already holds the real scheduling information.

This migration is intentionally lossy in the forward direction.  The downgrade
restores the constraint shape but cannot recover which rows were 'scheduled'
before the upgrade ran, because that information is discarded.  Do not rely on
the downgrade to restore data — it exists only to allow rolling back the
schema constraint if needed.
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Reclassify all scheduled rows; due_date is left untouched.
    op.execute("UPDATE todos SET state = 'next_action' WHERE state = 'scheduled'")

    # Shrink the CHECK constraint to remove 'scheduled'.
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('inbox','next_action','waiting_for','someday_maybe','done')",
    )


def downgrade() -> None:
    # Restores the constraint only — data cannot be recovered.
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('inbox','next_action','waiting_for','scheduled','someday_maybe','done')",
    )
