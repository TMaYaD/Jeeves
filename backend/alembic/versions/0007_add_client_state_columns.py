"""Add client-state columns to todos for bidirectional PowerSync replication

Revision ID: 0007
Revises: 0006
Create Date: 2026-04-19

Promotes six previously client-only columns on the Drift schema to first-class
Postgres columns so PowerSync can replicate them:

- waiting_for            TEXT NULL       (who / what a waiting_for task waits on)
- in_progress_since      TEXT NULL       (ISO-8601 timestamp; set on state=in_progress)
- time_spent_minutes     INTEGER NOT NULL DEFAULT 0
- blocked_by_todo_id     TEXT NULL       (id of another todo that must finish first)
- selected_for_today     BOOLEAN NULL    (daily planning tri-state: true/false/null)
- daily_selection_date   TEXT NULL       (yyyy-MM-dd of the daily planning run)

All six are additive and nullable (or have defaults), so existing rows are
unaffected.  The PowerSync publication created in 0006 is FOR TABLE and
automatically picks up column additions without republishing.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0007"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("todos", sa.Column("waiting_for", sa.Text(), nullable=True))
    op.add_column("todos", sa.Column("in_progress_since", sa.Text(), nullable=True))
    op.add_column(
        "todos",
        sa.Column(
            "time_spent_minutes",
            sa.Integer(),
            nullable=False,
            server_default=sa.text("0"),
        ),
    )
    op.add_column("todos", sa.Column("blocked_by_todo_id", sa.Text(), nullable=True))
    op.add_column("todos", sa.Column("selected_for_today", sa.Boolean(), nullable=True))
    op.add_column("todos", sa.Column("daily_selection_date", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("todos", "daily_selection_date")
    op.drop_column("todos", "selected_for_today")
    op.drop_column("todos", "blocked_by_todo_id")
    op.drop_column("todos", "time_spent_minutes")
    op.drop_column("todos", "in_progress_since")
    op.drop_column("todos", "waiting_for")
