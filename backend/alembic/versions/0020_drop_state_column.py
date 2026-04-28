"""Drop state column from todos table.

The state column has been a constant ('next_action' for every row) since
migration 0019 collapsed the last non-next_action state (in_progress).
Removing it eliminates dead scaffolding.

Revision ID: 0020
Revises: 0019
"""

import sqlalchemy as sa

from alembic import op

revision = "0020"
down_revision = "0019"
branch_labels = None
depends_on = None


def upgrade() -> None:
    # Drop the index and constraint referencing the column before dropping it.
    op.drop_index("ix_todos_user_state", table_name="todos")
    op.drop_constraint("ck_todos_state", "todos")
    op.drop_column("todos", "state")


def downgrade() -> None:
    op.add_column(
        "todos",
        sa.Column(
            "state",
            sa.String(50),
            nullable=False,
            server_default="next_action",
        ),
    )
    op.create_index("ix_todos_user_state", "todos", ["user_id", "state"])
    op.create_check_constraint(
        "ck_todos_state",
        "todos",
        "state IN ('next_action')",
    )
