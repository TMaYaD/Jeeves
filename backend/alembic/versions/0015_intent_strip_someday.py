"""Add intent column; strip someday_maybe state.

Adds a 3-value intent column (next | maybe | trash) to todos, migrates all
someday_maybe rows to next_action state + maybe intent, and removes
someday_maybe from the ck_todos_state check constraint.

Revision ID: 0015
Revises: 0014
"""

import sqlalchemy as sa

from alembic import op

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
    # Data loss: someday_maybe rows cannot be restored from intent='maybe' alone.
    op.drop_constraint("ck_todos_intent", "todos")
    op.drop_column("todos", "intent")
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('inbox','next_action','waiting_for','someday_maybe','done')",
    )
