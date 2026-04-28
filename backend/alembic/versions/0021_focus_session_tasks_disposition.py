"""Add disposition column to focus_session_tasks.

Records the user's per-task choice during session review:
  NULL     — task not yet reviewed (active session) or done task
  rollover — carry forward to next session's pre-selected list
  leave    — return to Next Actions pool (no state change needed)
  maybe    — defer; FocusSessionReviewNotifier writes intent='maybe' to todos

Revision ID: 0021
Revises: 0020
"""

import sqlalchemy as sa

from alembic import op

revision = "0021"
down_revision = "0020"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "focus_session_tasks",
        sa.Column("disposition", sa.Text(), nullable=True),
    )
    op.create_check_constraint(
        "ck_focus_session_tasks_disposition",
        "focus_session_tasks",
        "disposition IS NULL OR disposition IN ('rollover', 'leave', 'maybe')",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_focus_session_tasks_disposition",
        "focus_session_tasks",
        type_="check",
    )
    op.drop_column("focus_session_tasks", "disposition")
