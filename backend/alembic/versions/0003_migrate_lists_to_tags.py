"""Migrate todo_lists to tags; add state to todos

Replaces the folder-based TodoList model with a flexible Tag system
and a GTD-friendly state field on each Todo.

Revision ID: 0003
Revises: 0002
Create Date: 2026-04-11

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ── 1. Drop the list_id FK index and column from todos ────────────────────
    op.drop_index("ix_todos_list_id", table_name="todos")
    op.drop_column("todos", "list_id")

    # ── 2. Drop the todo_lists table (safe — early dev, no data to preserve) ──
    op.drop_index("ix_todo_lists_user_id", table_name="todo_lists")
    op.drop_table("todo_lists")

    # ── 3. Add state column to todos (defaults to "inbox") ────────────────────
    op.add_column(
        "todos",
        sa.Column("state", sa.String(50), nullable=False, server_default="inbox"),
    )

    # ── 4. Create tags table ──────────────────────────────────────────────────
    op.create_table(
        "tags",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("color", sa.String(20)),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
    )
    op.create_index("ix_tags_user_id", "tags", ["user_id"])
    op.create_unique_constraint("uq_tags_user_name", "tags", ["user_id", "name"])

    # ── 5. Create todo_tags junction table ────────────────────────────────────
    op.create_table(
        "todo_tags",
        sa.Column(
            "todo_id",
            sa.String(),
            sa.ForeignKey("todos.id", ondelete="CASCADE"),
            primary_key=True,
            nullable=False,
        ),
        sa.Column(
            "tag_id",
            sa.String(),
            sa.ForeignKey("tags.id", ondelete="CASCADE"),
            primary_key=True,
            nullable=False,
        ),
    )


def downgrade() -> None:
    # ── Reverse in opposite order ─────────────────────────────────────────────
    op.drop_table("todo_tags")
    op.drop_constraint("uq_tags_user_name", "tags")
    op.drop_index("ix_tags_user_id", "tags")
    op.drop_table("tags")

    op.drop_column("todos", "state")

    op.create_table(
        "todo_lists",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("color", sa.String(20)),
        sa.Column("icon_name", sa.String(100)),
        sa.Column("is_archived", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime()),
        sa.Column("user_id", sa.String(), sa.ForeignKey("users.id"), nullable=False),
    )
    op.create_index("ix_todo_lists_user_id", "todo_lists", ["user_id"])

    op.add_column(
        "todos",
        sa.Column("list_id", sa.String(), sa.ForeignKey("todo_lists.id")),
    )
    op.create_index("ix_todos_list_id", "todos", ["list_id"])
