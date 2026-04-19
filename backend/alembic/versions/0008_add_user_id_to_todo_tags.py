"""Add user_id to todo_tags for per-user PowerSync bucketing

Revision ID: 0008
Revises: 0007
Create Date: 2026-04-19

Denormalizes `user_id` from `todos` onto the `todo_tags` junction so the
PowerSync sync rule can filter junction rows by the bucket parameter
`user_id` — replacing the previous `global_todo_tags` bucket that forced
every client to download every user's junction rows.

Follows PowerSync's recommended "Denormalize Foreign Key onto Child Table"
pattern for many-to-many join tables:
  https://docs.powersync.com/sync/rules/many-to-many-join-tables

Backfill strategy: copy `todos.user_id` into every existing `todo_tags`
row via a correlated UPDATE … FROM.  The column is added nullable, back-
filled, then flipped to NOT NULL so the transition is crash-safe.

Integrity (application-level):
- A SQLAlchemy `before_flush` listener in app/todos/models.py fills
  `user_id` on every pending TodoTag that hasn't had it set explicitly,
  so the ORM-cascade path (`todo.tags = [...]`) keeps working without
  call-site changes.
- `todos.user_id` is immutable (no reassign-todo-to-another-user flow),
  so the denormalized copy cannot drift.  A CHECK constraint enforcing
  the parent match would need a trigger (subqueries aren't allowed in
  CHECK) and is deliberately out of scope.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0008"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ── 1. Add column nullable so the backfill has room to run ─────────────
    op.add_column("todo_tags", sa.Column("user_id", sa.String(), nullable=True))

    # ── 2. Backfill from the parent todo ───────────────────────────────────
    op.execute(
        "UPDATE todo_tags SET user_id = todos.user_id FROM todos WHERE todo_tags.todo_id = todos.id"
    )

    # ── 3. Flip to NOT NULL now that every row is populated ────────────────
    op.alter_column("todo_tags", "user_id", nullable=False)

    # ── 4. FK to users (match todos.user_id ON DELETE CASCADE) ─────────────
    op.create_foreign_key(
        "fk_todo_tags_user_id_users",
        "todo_tags",
        "users",
        ["user_id"],
        ["id"],
        ondelete="CASCADE",
    )

    # ── 5. Index — PowerSync's bucket SELECT filters on user_id ────────────
    op.create_index("ix_todo_tags_user_id", "todo_tags", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_todo_tags_user_id", table_name="todo_tags")
    op.drop_constraint("fk_todo_tags_user_id_users", "todo_tags", type_="foreignkey")
    op.drop_column("todo_tags", "user_id")
