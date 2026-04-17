"""Standardise all DateTime columns to TIMESTAMP WITH TIME ZONE (UTC)

Revision ID: 0005
Revises: 0004
Create Date: 2026-04-17

Converts every naive TIMESTAMP column to TIMESTAMP WITH TIME ZONE so that
timezone-aware datetimes (datetime.now(UTC)) are accepted by asyncpg without
the "can't subtract offset-naive and offset-aware datetimes" 500 error.

Existing values are preserved as-is; Postgres interprets bare timestamps as
UTC on conversion when no explicit AT TIME ZONE is given, which is correct
because all application code already uses UTC for writes.

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
        batch_op.alter_column("created_at", type_=_TSTZ, existing_type=_TS, existing_nullable=False)
        batch_op.alter_column("updated_at", type_=_TSTZ, existing_type=_TS, existing_nullable=True)

    with op.batch_alter_table("todos") as batch_op:
        batch_op.alter_column("due_date", type_=_TSTZ, existing_type=_TS, existing_nullable=True)
        batch_op.alter_column("created_at", type_=_TSTZ, existing_type=_TS, existing_nullable=False)
        batch_op.alter_column("updated_at", type_=_TSTZ, existing_type=_TS, existing_nullable=True)

    with op.batch_alter_table("reminders") as batch_op:
        batch_op.alter_column(
            "scheduled_at", type_=_TSTZ, existing_type=_TS, existing_nullable=True
        )
        batch_op.alter_column("created_at", type_=_TSTZ, existing_type=_TS, existing_nullable=False)

    with op.batch_alter_table("locations") as batch_op:
        batch_op.alter_column("created_at", type_=_TSTZ, existing_type=_TS, existing_nullable=False)

    with op.batch_alter_table("recurrence_rules") as batch_op:
        batch_op.alter_column("until", type_=_TSTZ, existing_type=_TS, existing_nullable=True)


def downgrade() -> None:
    with op.batch_alter_table("recurrence_rules") as batch_op:
        batch_op.alter_column("until", type_=_TS, existing_type=_TSTZ, existing_nullable=True)

    with op.batch_alter_table("locations") as batch_op:
        batch_op.alter_column("created_at", type_=_TS, existing_type=_TSTZ, existing_nullable=False)

    with op.batch_alter_table("reminders") as batch_op:
        batch_op.alter_column("created_at", type_=_TS, existing_type=_TSTZ, existing_nullable=False)
        batch_op.alter_column(
            "scheduled_at", type_=_TS, existing_type=_TSTZ, existing_nullable=True
        )

    with op.batch_alter_table("todos") as batch_op:
        batch_op.alter_column("updated_at", type_=_TS, existing_type=_TSTZ, existing_nullable=True)
        batch_op.alter_column("created_at", type_=_TS, existing_type=_TSTZ, existing_nullable=False)
        batch_op.alter_column("due_date", type_=_TS, existing_type=_TSTZ, existing_nullable=True)

    with op.batch_alter_table("users") as batch_op:
        batch_op.alter_column("updated_at", type_=_TS, existing_type=_TSTZ, existing_nullable=True)
        batch_op.alter_column("created_at", type_=_TS, existing_type=_TSTZ, existing_nullable=False)
