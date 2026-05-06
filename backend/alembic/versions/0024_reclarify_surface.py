"""Add next_action_text and last_next_action_completion_at to todos.

This migration adds two columns supporting the re-clarification surface (issue #237):

- next_action_text: the current next-action cursor; NULL = Actionless (no action defined).
- last_next_action_completion_at: timestamped when a focus session closes with this task
  non-done; used to detect staleness (task was worked on since last clarification).

Both columns are nullable with no default and no backfill. Existing rows start NULL.
Tasks with next_action_text = NULL will surface as Actionless on the first planning
session after the migration — this is intentional, prompting a one-time clarification pass.

Revision ID: 0024
Revises: 0023
"""

import sqlalchemy as sa

from alembic import op

revision = "0024"
down_revision = "0023"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "todos",
        sa.Column("next_action_text", sa.Text(), nullable=True),
    )
    op.add_column(
        "todos",
        sa.Column(
            "last_next_action_completion_at",
            sa.DateTime(timezone=True),
            nullable=True,
        ),
    )


def downgrade() -> None:
    op.drop_column("todos", "last_next_action_completion_at")
    op.drop_column("todos", "next_action_text")
