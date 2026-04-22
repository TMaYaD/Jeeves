"""Add solana_public_key to users and make email/hashed_password nullable

Revision ID: 0010
Revises: 0009
Create Date: 2026-04-22

Adds support for Sign-In With Solana (SWS) users who authenticate via their
Solana wallet (Solana Seeker / Seed Vault) rather than email + password.

Schema changes:
- ``users.solana_public_key`` — nullable, unique, indexed.  Non-null for SWS
  users; null for password users.
- ``users.email`` — changed from NOT NULL to nullable.  Password users always
  have an email; SWS users do not.
- ``users.hashed_password`` — changed from NOT NULL to nullable.  Password
  users always have a hash; SWS users do not.

Data integrity: existing rows are unaffected — their email and hashed_password
values remain as-is; the new column defaults to NULL.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    # Add solana_public_key column.
    op.add_column(
        "users",
        sa.Column("solana_public_key", sa.String(), nullable=True),
    )
    op.create_index("ix_users_solana_public_key", "users", ["solana_public_key"], unique=True)

    # Make email nullable (was NOT NULL).
    op.alter_column("users", "email", nullable=True)

    # Make hashed_password nullable (was NOT NULL).
    op.alter_column("users", "hashed_password", nullable=True)


def downgrade() -> None:
    # Reverse nullable changes — will fail if any row has NULL values.
    op.alter_column("users", "hashed_password", nullable=False)
    op.alter_column("users", "email", nullable=False)

    op.drop_index("ix_users_solana_public_key", table_name="users")
    op.drop_column("users", "solana_public_key")
