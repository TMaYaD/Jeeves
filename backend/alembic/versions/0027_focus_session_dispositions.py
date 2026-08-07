"""Create focus_session_dispositions — durable home for off-Plan Dispositions.

Revision ID: 0027
Revises: 0026
Create Date: 2026-07-17

Off-Plan engagement became production-reachable via the task-detail
``Start focus`` affordance (issue #180), but the Review path had nowhere to
persist a Disposition for an Outcome that was engaged but never on the Plan:
dispositions lived only on ``focus_session_tasks`` rows, which off-Plan
Outcomes do not have (the Plan never auto-grows — ADR-0002).

Off-Plan Dispositions get their own table rather than a
discriminator column on ``focus_session_tasks`` (which would force every Plan
reader to filter, and any miss would silently auto-grow the Plan).  This
migration creates that table, mirroring ``focus_session_tasks``' PowerSync
conventions:

- ``id TEXT UNIQUE`` with a ``gen_random_uuid()`` server default — PowerSync
  identifies every synced row by ``id`` (mirror migration 0025).
- ``(focus_session_id, task_id)`` composite primary key — the domain key.
- denormalized ``user_id`` (NOT NULL, FK to users ON DELETE CASCADE, indexed)
  so the per-user bucket filters with no JOIN (mirror migration 0008 / 0025).
- the disposition CHECK constraint, matching ``focus_session_tasks``.
- the table added to the powersync publication so it replicates to clients.

Purely additive: no existing data is touched.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0027"
down_revision: str | None = "0026"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "focus_session_dispositions",
        sa.Column(
            "id",
            sa.String(),
            nullable=True,
            unique=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "focus_session_id",
            sa.String(),
            sa.ForeignKey("focus_sessions.id"),
            primary_key=True,
        ),
        sa.Column(
            "task_id",
            sa.String(),
            sa.ForeignKey("todos.id"),
            primary_key=True,
        ),
        sa.Column("disposition", sa.Text(), nullable=True),
        sa.Column(
            "user_id",
            sa.String(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "disposition IS NULL OR disposition IN ('rollover', 'leave', 'maybe')",
            name="ck_focus_session_dispositions_disposition",
        ),
    )
    op.create_index(
        "ix_focus_session_dispositions_user_id",
        "focus_session_dispositions",
        ["user_id"],
    )

    # Replicate the new table to clients (no-op when the publication does not
    # exist, e.g. in test environments).
    op.execute(
        """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') THEN
    ALTER PUBLICATION powersync ADD TABLE focus_session_dispositions;
  END IF;
END $$;
"""
    )


def downgrade() -> None:
    op.execute(
        """
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') THEN
    ALTER PUBLICATION powersync DROP TABLE focus_session_dispositions;
  END IF;
END $$;
"""
    )
    op.drop_index(
        "ix_focus_session_dispositions_user_id",
        table_name="focus_session_dispositions",
    )
    op.drop_table("focus_session_dispositions")
