"""Add GTD fields: tags.type, todos energy/estimate/capture/state-check

Revision ID: 0004
Revises: 0003
Create Date: 2026-04-12

Adds:
- tags.type  TEXT(20) NOT NULL DEFAULT 'context'  ('context'|'project'|'area'|'label')
- todos.time_estimate  INTEGER NULLABLE  (minutes)
- todos.energy_level   TEXT(20) NULLABLE ('low'|'medium'|'high')
- todos.capture_source TEXT(50) NULLABLE ('manual'|'share_sheet'|'voice'|'ai_parse')
- CHECK constraint on todos.state
- Compound index (user_id, state) on todos
- Index on tags.type
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ── 1. Add type column to tags ─────────────────────────────────────────────
    op.add_column(
        "tags",
        sa.Column("type", sa.String(20), nullable=False, server_default="context"),
    )
    op.create_index("ix_tags_type", "tags", ["type"])

    # ── 2. Add GTD columns to todos ───────────────────────────────────────────
    op.add_column("todos", sa.Column("time_estimate", sa.Integer(), nullable=True))
    op.add_column("todos", sa.Column("energy_level", sa.String(20), nullable=True))
    op.add_column("todos", sa.Column("capture_source", sa.String(50), nullable=True))

    # ── 3. Compound index for GTD state queries ───────────────────────────────
    op.create_index("ix_todos_user_state", "todos", ["user_id", "state"])

    # ── 4. CHECK constraints (Postgres only — SQLite test DB uses create_all) ─
    # state must be a valid GTD state
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('inbox','next_action','waiting_for','scheduled','someday_maybe','done')",
    )
    # energy_level must be null or valid
    op.create_check_constraint(
        "ck_todos_energy_level",
        "todos",
        "energy_level IS NULL OR energy_level IN ('low','medium','high')",
    )
    # tags.type must be valid
    op.create_check_constraint(
        "ck_tags_type",
        "tags",
        "type IN ('context','project','area','label')",
    )


def downgrade() -> None:
    op.drop_constraint("ck_tags_type", "tags")
    op.drop_constraint("ck_todos_energy_level", "todos")
    op.drop_constraint("ck_todos_state", "todos")

    op.drop_index("ix_todos_user_state", "todos")

    op.drop_column("todos", "capture_source")
    op.drop_column("todos", "energy_level")
    op.drop_column("todos", "time_estimate")

    op.drop_index("ix_tags_type", "tags")
    op.drop_column("tags", "type")
