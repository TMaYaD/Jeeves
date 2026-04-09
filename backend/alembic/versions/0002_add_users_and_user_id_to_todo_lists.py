"""Add users table and user_id FK to todo_lists and todos

Revision ID: 0002
Revises: 0001
Create Date: 2026-04-09

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("email", sa.String(255), nullable=False),
        sa.Column("hashed_password", sa.String(), nullable=False),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default="true"),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime()),
    )
    op.create_index("ix_users_email", "users", ["email"], unique=True)

    op.add_column(
        "todo_lists",
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
    )
    op.create_index("ix_todo_lists_user_id", "todo_lists", ["user_id"])

    op.add_column(
        "todos",
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
    )
    op.create_index("ix_todos_user_id", "todos", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_todos_user_id", "todos")
    op.drop_column("todos", "user_id")

    op.drop_index("ix_todo_lists_user_id", "todo_lists")
    op.drop_column("todo_lists", "user_id")

    op.drop_index("ix_users_email", "users")
    op.drop_table("users")
