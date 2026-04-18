"""Add PowerSync publication and todo_tags.id for upload idempotency

Revision ID: 0006
Revises: 0005
Create Date: 2026-04-18

Adds:
- todo_tags.id TEXT UNIQUE — stores the PowerSync-assigned UUID so the
  upload handler can locate and delete rows by entry.id.
- PostgreSQL publication "powersync" covering all tables that PowerSync
  replicates.  Required for logical replication to work.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Tables exposed to PowerSync via logical replication.
_PUBLICATION_TABLES = "todos, tags, todo_tags, locations, reminders, recurrence_rules"


def upgrade() -> None:
    # ── 1. Add id column to todo_tags ──────────────────────────────────────────
    op.add_column(
        "todo_tags",
        sa.Column(
            "id",
            sa.String(),
            nullable=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
    )
    # Back-fill existing rows so PowerSync can sync them with a stable id.
    op.execute("UPDATE todo_tags SET id = gen_random_uuid() WHERE id IS NULL")
    op.create_index("ix_todo_tags_id", "todo_tags", ["id"], unique=True)

    # ── 2. Create PowerSync logical-replication publication ────────────────────
    op.execute(f"CREATE PUBLICATION powersync FOR TABLE {_PUBLICATION_TABLES}")


def downgrade() -> None:
    op.execute("DROP PUBLICATION IF EXISTS powersync")

    op.drop_index("ix_todo_tags_id", table_name="todo_tags")
    op.drop_column("todo_tags", "id")
