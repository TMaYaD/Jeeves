"""Add clarified column; strip inbox state.

Adds a boolean clarified column (default True) to todos, migrates all
inbox rows to next_action state + clarified = false, and removes
inbox from the ck_todos_state check constraint.

Revision ID: 0016
Revises: 0015
"""

import sqlalchemy as sa

from alembic import op

revision = "0016"
down_revision = "0015"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "todos",
        sa.Column("clarified", sa.Boolean(), nullable=False, server_default=sa.true()),
    )
    op.execute("UPDATE todos SET clarified = false, state = 'next_action' WHERE state = 'inbox'")
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('next_action','waiting_for','done')",
    )
    # Remove server_default — application code controls this going forward.
    op.alter_column("todos", "clarified", server_default=None)


def downgrade() -> None:
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('inbox','next_action','waiting_for','done')",
    )
    op.execute("UPDATE todos SET state = 'inbox' WHERE clarified = false")
    op.drop_column("todos", "clarified")
