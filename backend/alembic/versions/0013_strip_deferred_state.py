"""Strip deferred state: collapse all deferred todos to next_action.

deferred was a client-only state. The server CHECK constraint still
included it; this migration removes it and tightens the constraint.

Downgrade: re-adds 'deferred' to the constraint but cannot restore
which rows were originally deferred — intentionally lossy.

Revision ID: 0013
Revises: 0012
"""

from alembic import op

revision = "0013"
down_revision = "0012"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("UPDATE todos SET state = 'next_action' WHERE state = 'deferred'")
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('inbox','next_action','waiting_for','someday_maybe','done')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_todos_state", "todos")
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('inbox','next_action','waiting_for','someday_maybe','deferred','done')",
    )
