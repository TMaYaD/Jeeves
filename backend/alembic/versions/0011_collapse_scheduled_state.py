"""Collapse scheduled state: rewrite all scheduled todos to next_action.

The scheduled GTD state carried no behavior beyond a list view. All rows
are collapsed to next_action with due_date preserved.

Downgrade note: the constraint can be restored, but which rows were
originally scheduled cannot be recovered — this is intentional and lossy
in the forward direction.

Revision ID: 0011
Revises: 0010
Create Date: 2026-04-27
"""

from alembic import op

revision = "0011"
down_revision = "0010"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("UPDATE todos SET state = 'next_action' WHERE state = 'scheduled'")
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
        "state IN ('inbox','next_action','waiting_for','scheduled','someday_maybe','done')",
    )
