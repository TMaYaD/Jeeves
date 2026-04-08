"""Initial schema: todos, lists, reminders, locations, recurrence_rules

Revision ID: 0001
Revises:
Create Date: 2026-04-09

"""

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "todo_lists",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("color", sa.String(20)),
        sa.Column("icon_name", sa.String(100)),
        sa.Column("is_archived", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime()),
    )

    op.create_table(
        "locations",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("name", sa.String(255), nullable=False),
        sa.Column("latitude", sa.Float(), nullable=False),
        sa.Column("longitude", sa.Float(), nullable=False),
        sa.Column("radius_meters", sa.Float(), nullable=False, server_default="100.0"),
        sa.Column("address", sa.String(500)),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.now()),
    )

    op.create_table(
        "todos",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("title", sa.String(500), nullable=False),
        sa.Column("notes", sa.Text()),
        sa.Column("completed", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("priority", sa.Integer()),
        sa.Column("due_date", sa.DateTime()),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime()),
        sa.Column("list_id", sa.String(), sa.ForeignKey("todo_lists.id")),
        sa.Column("location_id", sa.String(), sa.ForeignKey("locations.id")),
    )
    op.create_index("ix_todos_list_id", "todos", ["list_id"])
    op.create_index("ix_todos_completed", "todos", ["completed"])

    op.create_table(
        "reminders",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column("todo_id", sa.String(), sa.ForeignKey("todos.id"), nullable=False),
        sa.Column("type", sa.String(20), nullable=False),
        sa.Column("scheduled_at", sa.DateTime()),
        sa.Column("location_id", sa.String(), sa.ForeignKey("locations.id")),
        sa.Column("on_arrival", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("on_departure", sa.Boolean(), nullable=False, server_default="false"),
        sa.Column("created_at", sa.DateTime(), nullable=False, server_default=sa.func.now()),
    )
    op.create_index("ix_reminders_todo_id", "reminders", ["todo_id"])

    op.create_table(
        "recurrence_rules",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column(
            "todo_id",
            sa.String(),
            sa.ForeignKey("todos.id"),
            unique=True,
            nullable=False,
        ),
        sa.Column("frequency", sa.String(20), nullable=False),
        sa.Column("interval", sa.Integer(), nullable=False, server_default="1"),
        sa.Column("by_day_of_week", sa.String(50)),
        sa.Column("by_day_of_month", sa.Integer()),
        sa.Column("until", sa.DateTime()),
        sa.Column("count", sa.Integer()),
    )


def downgrade() -> None:
    op.drop_table("recurrence_rules")
    op.drop_index("ix_reminders_todo_id", "reminders")
    op.drop_table("reminders")
    op.drop_index("ix_todos_completed", "todos")
    op.drop_index("ix_todos_list_id", "todos")
    op.drop_table("todos")
    op.drop_table("locations")
    op.drop_table("todo_lists")
