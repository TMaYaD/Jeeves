"""Add id and user_id to focus_session_tasks for per-user PowerSync bucketing

Revision ID: 0025
Revises: 0024
Create Date: 2026-07-12

The by_user_focus_session_tasks bucket JOINed through focus_sessions to
apply the per-user filter, but PowerSync rejects JOINs in bucket data
queries as a *fatal* sync-rules error — the whole config fails to load and
no bucket replicates (issue #381).  Switch the junction to the same
"Denormalize Foreign Key onto Child Table" pattern already used by
todo_tags (migrations 0006 + 0008):
  https://docs.powersync.com/sync/rules/many-to-many-join-tables

- id TEXT UNIQUE (mirror 0006): PowerSync identifies every synced row by
  an `id` column; the client already declares one (Drift schema v17).
  Server-side default gen_random_uuid() covers rows created outside the
  client.
- user_id (mirror 0008): denormalized from the parent focus_sessions row
  so the bucket can filter with no JOIN.  Added nullable, backfilled via
  correlated UPDATE … FROM, then flipped to NOT NULL so the transition is
  crash-safe.

Integrity (application-level): `focus_sessions.user_id` is immutable (no
reassign-session flow), so the denormalized copy cannot drift.  Every
insert sets user_id explicitly and NOT NULL enforces it; a CHECK
constraint enforcing the parent match would need a trigger (subqueries
aren't allowed in CHECK) and is deliberately out of scope.

No publication change — 0019 already added focus_session_tasks to the
powersync publication.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0025"
down_revision: str | None = "0024"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # ── 1. id: PowerSync row identifier (mirror 0006) ───────────────────────
    op.add_column(
        "focus_session_tasks",
        sa.Column(
            "id",
            sa.String(),
            nullable=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
    )
    # Back-fill existing rows so PowerSync can sync them with a stable id.
    op.execute("UPDATE focus_session_tasks SET id = gen_random_uuid() WHERE id IS NULL")
    op.create_index("ix_focus_session_tasks_id", "focus_session_tasks", ["id"], unique=True)

    # ── 2. user_id: add column nullable so the backfill has room to run ─────
    op.add_column("focus_session_tasks", sa.Column("user_id", sa.String(), nullable=True))

    # ── 3. Backfill from the parent focus session ───────────────────────────
    op.execute(
        "UPDATE focus_session_tasks SET user_id = focus_sessions.user_id "
        "FROM focus_sessions WHERE focus_session_tasks.focus_session_id = focus_sessions.id"
    )

    # ── 4. Flip to NOT NULL now that every row is populated ─────────────────
    op.alter_column("focus_session_tasks", "user_id", nullable=False)

    # ── 5. FK to users (match todo_tags.user_id ON DELETE CASCADE) ──────────
    op.create_foreign_key(
        "fk_focus_session_tasks_user_id_users",
        "focus_session_tasks",
        "users",
        ["user_id"],
        ["id"],
        ondelete="CASCADE",
    )

    # ── 6. Index — PowerSync's bucket SELECT filters on user_id ─────────────
    op.create_index("ix_focus_session_tasks_user_id", "focus_session_tasks", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_focus_session_tasks_user_id", table_name="focus_session_tasks")
    op.drop_constraint(
        "fk_focus_session_tasks_user_id_users", "focus_session_tasks", type_="foreignkey"
    )
    op.drop_column("focus_session_tasks", "user_id")
    op.drop_index("ix_focus_session_tasks_id", table_name="focus_session_tasks")
    op.drop_column("focus_session_tasks", "id")
