"""Strip blocked state and drop blocked_by_todo_id column.

blocked was a client-only state. The server check constraint never
included it, so the UPDATE is a safety no-op on Postgres. The column
drop is the meaningful change.

Downgrade: column cannot be recovered; intentionally lossy in alpha.

Revision ID: 0012
Revises: 0011
"""

from alembic import op

revision = "0012"
down_revision = "0011"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute("UPDATE todos SET state = 'next_action' WHERE state = 'blocked'")
    op.drop_column("todos", "blocked_by_todo_id")


def downgrade() -> None:
    raise NotImplementedError("blocked_by_todo_id cannot be recovered after PR B")
