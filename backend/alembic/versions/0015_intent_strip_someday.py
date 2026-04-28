"""Add intent column; strip someday_maybe state.

Adds a 3-value intent column (next | maybe | trash) to todos, migrates all
someday_maybe rows to next_action state + maybe intent, and removes
someday_maybe from the ck_todos_state check constraint.

Revision ID: 0015
Revises: 0014
"""

from alembic import op
import sqlalchemy as sa

revision = "0015"
down_revision = "0014"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "todos",
        sa.Column("intent", sa.String(), nullable=False, server_default="next"),
    )
    op.create_check_constraint(
        "ck_todos_intent",
        "todos",
        "intent IN ('next','maybe','trash')",
    )
    op.execute(
        "UPDATE todos SET intent = 'maybe', state = 'next_action' WHERE state = 'someday_maybe'"
    )
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('inbox','next_action','waiting_for','done')",
    )


def downgrade() -> None:
    raise NotImplementedError("Migration 0015 is intentionally irreversible (alpha build).")
