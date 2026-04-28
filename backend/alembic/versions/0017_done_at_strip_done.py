"""Add done_at timestamp; strip done state.

Adds a nullable done_at TIMESTAMPTZ column, backfills it from updated_at
for rows that are semantically done (state='done' OR completed=true),
collapses done rows to next_action, removes done from the ck_todos_state
CHECK constraint, and drops the now-superseded completed boolean.

Revision ID: 0017
Revises: 0016
"""

import sqlalchemy as sa

from alembic import op

revision = "0017"
down_revision = "0016"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("todos", sa.Column("done_at", sa.DateTime(timezone=True), nullable=True))
    # Backfill: cover both state='done' rows and rows where completed=true but
    # state diverged — nothing in the schema enforced co-setting of both fields.
    op.execute("UPDATE todos SET done_at = updated_at WHERE state = 'done' OR completed = true")
    op.execute("UPDATE todos SET state = 'next_action' WHERE state = 'done'")
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('next_action','waiting_for','in_progress')",
    )
    # in_progress stays until PR I retires it.
    op.drop_index("ix_todos_completed", table_name="todos", if_exists=True)
    op.drop_column("todos", "completed")


def downgrade() -> None:
    op.add_column(
        "todos",
        sa.Column("completed", sa.Boolean(), nullable=False, server_default=sa.false()),
    )
    op.execute("UPDATE todos SET completed = (done_at IS NOT NULL)")
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('next_action','waiting_for','in_progress','done')",
    )
    op.execute("UPDATE todos SET state = 'done' WHERE done_at IS NOT NULL")
    op.drop_column("todos", "done_at")
    op.alter_column("todos", "completed", server_default=None)
    op.create_index("ix_todos_completed", "todos", ["completed"])
