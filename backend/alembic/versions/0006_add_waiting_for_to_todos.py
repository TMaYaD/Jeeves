"""Add waiting_for column to todos

Revision ID: 0006
Revises: 0005
Create Date: 2026-04-17

Adds todos.waiting_for TEXT(255) NULLABLE to store who/what a task is
waiting on as a dedicated field rather than as a generic tag.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0006"
down_revision: str | None = "0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("todos", sa.Column("waiting_for", sa.String(255), nullable=True))


def downgrade() -> None:
    op.drop_column("todos", "waiting_for")
