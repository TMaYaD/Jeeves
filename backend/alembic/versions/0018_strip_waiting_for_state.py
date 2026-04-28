"""Strip waiting_for state; waiting_for text column becomes the source of truth.

All rows with state='waiting_for' are collapsed to 'next_action'. The
waiting_for TEXT column is unchanged — the Waiting For list is now sourced by:
  WHERE waiting_for IS NOT NULL AND clarified = true AND done_at IS NULL AND intent = 'next'

Revision ID: 0018
Revises: 0017
"""

from alembic import op

revision = "0018"
down_revision = "0017"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("UPDATE todos SET state = 'next_action' WHERE state = 'waiting_for'")
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('next_action','in_progress')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('next_action','waiting_for','in_progress')",
    )
    raise NotImplementedError(
        "Migration 0018 is irreversible: prior waiting_for state cannot be reconstructed safely."
    )
