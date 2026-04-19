"""Add refresh_tokens table for long-lived session persistence

Revision ID: 0009
Revises: 0008
Create Date: 2026-04-20

Adds a `refresh_tokens` table that stores SHA-256 hashes of opaque random
tokens issued at login/register.  Short-lived access tokens (15 min) can be
silently renewed by the client using a long-lived refresh token (1 year)
without re-prompting for credentials — enabling offline-first session
persistence (issue #106).

Only the hash is stored; the raw token is sent to the client once and never
persisted, so a DB breach cannot expose live tokens.  Token rotation on use
(revoke old, issue new) limits the blast radius if a refresh token leaks.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "refresh_tokens",
        sa.Column("id", sa.String(), primary_key=True),
        sa.Column(
            "user_id",
            sa.String(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("token_hash", sa.String(), unique=True, nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_refresh_tokens_user_id", "refresh_tokens", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_refresh_tokens_user_id", table_name="refresh_tokens")
    op.drop_table("refresh_tokens")
