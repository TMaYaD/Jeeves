"""Standardise all DateTime columns to TIMESTAMP WITH TIME ZONE (UTC)

Revision ID: 0005
Revises: 0004
Create Date: 2026-04-17

Converts every naive TIMESTAMP column to TIMESTAMP WITH TIME ZONE so that
timezone-aware datetimes (datetime.now(UTC)) are accepted by asyncpg without
the "can't subtract offset-naive and offset-aware datetimes" 500 error.

PostgreSQL does NOT interpret bare timestamps as UTC by default — it uses the
session/database timezone. All alter_column calls supply an explicit
postgresql_using clause ("col AT TIME ZONE 'UTC'") so that existing values are
treated as UTC regardless of the session timezone setting.

Tables / columns altered:
- users:            created_at, updated_at
- todos:            due_date, created_at, updated_at
- reminders:        scheduled_at, created_at
- locations:        created_at
- recurrence_rules: until
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_TSTZ = sa.DateTime(timezone=True)
_TS = sa.DateTime(timezone=False)


def upgrade() -> None:
    with op.batch_alter_table("users") as batch_op:
        batch_op.alter_column(
            "created_at",
            type_=_TSTZ,
            existing_type=_TS,
            existing_nullable=False,
            postgresql_using="created_at AT TIME ZONE 'UTC'",
        )
        batch_op.alter_column(
            "updated_at",
            type_=_TSTZ,
            existing_type=_TS,
            existing_nullable=True,
            postgresql_using="updated_at AT TIME ZONE 'UTC'",
        )

    with op.batch_alter_table("todos") as batch_op:
        batch_op.alter_column(
            "due_date",
            type_=_TSTZ,
            existing_type=_TS,
            existing_nullable=True,
            postgresql_using="due_date AT TIME ZONE 'UTC'",
        )
        batch_op.alter_column(
            "created_at",
            type_=_TSTZ,
            existing_type=_TS,
            existing_nullable=False,
            postgresql_using="created_at AT TIME ZONE 'UTC'",
        )
        batch_op.alter_column(
            "updated_at",
            type_=_TSTZ,
            existing_type=_TS,
            existing_nullable=True,
            postgresql_using="updated_at AT TIME ZONE 'UTC'",
        )

    with op.batch_alter_table("reminders") as batch_op:
        batch_op.alter_column(
            "scheduled_at",
            type_=_TSTZ,
            existing_type=_TS,
            existing_nullable=True,
            postgresql_using="scheduled_at AT TIME ZONE 'UTC'",
        )
        batch_op.alter_column(
            "created_at",
            type_=_TSTZ,
            existing_type=_TS,
            existing_nullable=False,
            postgresql_using="created_at AT TIME ZONE 'UTC'",
        )

    with op.batch_alter_table("locations") as batch_op:
        batch_op.alter_column(
            "created_at",
            type_=_TSTZ,
            existing_type=_TS,
            existing_nullable=False,
            postgresql_using="created_at AT TIME ZONE 'UTC'",
        )

    with op.batch_alter_table("recurrence_rules") as batch_op:
        batch_op.alter_column(
            "until",
            type_=_TSTZ,
            existing_type=_TS,
            existing_nullable=True,
            postgresql_using="until AT TIME ZONE 'UTC'",
        )


def downgrade() -> None:
    with op.batch_alter_table("recurrence_rules") as batch_op:
        batch_op.alter_column(
            "until",
            type_=_TS,
            existing_type=_TSTZ,
            existing_nullable=True,
            postgresql_using="until AT TIME ZONE 'UTC'",
        )

    with op.batch_alter_table("locations") as batch_op:
        batch_op.alter_column(
            "created_at",
            type_=_TS,
            existing_type=_TSTZ,
            existing_nullable=False,
            postgresql_using="created_at AT TIME ZONE 'UTC'",
        )

    with op.batch_alter_table("reminders") as batch_op:
        batch_op.alter_column(
            "created_at",
            type_=_TS,
            existing_type=_TSTZ,
            existing_nullable=False,
            postgresql_using="created_at AT TIME ZONE 'UTC'",
        )
        batch_op.alter_column(
            "scheduled_at",
            type_=_TS,
            existing_type=_TSTZ,
            existing_nullable=True,
            postgresql_using="scheduled_at AT TIME ZONE 'UTC'",
        )

    with op.batch_alter_table("todos") as batch_op:
        batch_op.alter_column(
            "updated_at",
            type_=_TS,
            existing_type=_TSTZ,
            existing_nullable=True,
            postgresql_using="updated_at AT TIME ZONE 'UTC'",
        )
        batch_op.alter_column(
            "created_at",
            type_=_TS,
            existing_type=_TSTZ,
            existing_nullable=False,
            postgresql_using="created_at AT TIME ZONE 'UTC'",
        )
        batch_op.alter_column(
            "due_date",
            type_=_TS,
            existing_type=_TSTZ,
            existing_nullable=True,
            postgresql_using="due_date AT TIME ZONE 'UTC'",
        )

    with op.batch_alter_table("users") as batch_op:
        batch_op.alter_column(
            "updated_at",
            type_=_TS,
            existing_type=_TSTZ,
            existing_nullable=True,
            postgresql_using="updated_at AT TIME ZONE 'UTC'",
        )
        batch_op.alter_column(
            "created_at",
            type_=_TS,
            existing_type=_TSTZ,
            existing_nullable=False,
            postgresql_using="created_at AT TIME ZONE 'UTC'",
        )
