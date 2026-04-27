"""Add time_logs table for per-task focus time tracking.

time_spent_minutes on todos becomes a denormalized cache: recomputed from
SUM(time_logs) whenever a log row is closed, rather than computed inline.
Pomodoro sprints no longer write directly to time_spent_minutes.

Revision ID: 0014
Revises: 0013
"""

import sqlalchemy as sa
from alembic import op

revision = "0014"
down_revision = "0013"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "time_logs",
        sa.Column("id", sa.String, primary_key=True),
        sa.Column("user_id", sa.String, nullable=False),
        sa.Column(
            "task_id",
            sa.String,
            sa.ForeignKey("todos.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_time_logs_user_id", "time_logs", ["user_id"])
    op.create_index("ix_time_logs_task_id", "time_logs", ["task_id"])
    # At most one open log (ended_at IS NULL) per user at any moment.
    op.execute(
        "CREATE UNIQUE INDEX uix_time_logs_active_per_user "
        "ON time_logs (user_id) WHERE ended_at IS NULL"
    )
    op.execute("ALTER PUBLICATION powersync ADD TABLE time_logs")


def downgrade() -> None:
    op.execute("ALTER PUBLICATION powersync DROP TABLE time_logs")
    op.drop_table("time_logs")
