"""Add the Minimal Sync Server op log and Member registry (issue #546).

Revision ID: 0031
Revises: 0030
Create Date: 2026-07-28

Purely additive: two new tables, no existing table touched, nothing dropped.
``ops`` is the append-only per-Workspace log of opaque envelopes (ADR-0026) and
``members`` is the stub public-key registry the walking skeleton verifies
signatures against (ADR-0028 replaces its trust model with the Root chain in
#548 — the shape stays, the authority arrives later).

Neither table joins the PowerSync publication.  The op log is the *replacement*
for that replication path, not a participant in it; the old stack keeps running
untouched until the cutover in #553.

``ops.seq`` is BIGSERIAL and is a transport cursor only — never causality,
never a merge input.  ``compacted_by`` ships unused: #555's prune ops set it,
and default pulls already exclude non-NULL rows so soft-deleted history stays
retrievable on demand.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0031"
down_revision: str | None = "0030"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "members",
        sa.Column("member_id", sa.Uuid(), primary_key=True),
        sa.Column(
            "user_id",
            sa.String,
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("sign_pk", sa.LargeBinary(), nullable=False),
        sa.Column("key_id", sa.LargeBinary(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_index("ix_members_user_id", "members", ["user_id"])

    op.create_table(
        "ops",
        sa.Column("seq", sa.BigInteger(), primary_key=True, autoincrement=True),
        sa.Column("workspace_id", sa.Uuid(), nullable=False),
        sa.Column("envelope", sa.LargeBinary(), nullable=False),
        sa.Column("op_class", sa.SmallInteger(), nullable=False),
        sa.Column("key_epoch", sa.Integer(), nullable=False),
        sa.Column("op_id", sa.Uuid(), nullable=False),
        sa.Column("author_member_id", sa.Uuid(), nullable=False),
        sa.Column("author_key_id", sa.LargeBinary(), nullable=False),
        sa.Column("author_seq", sa.BigInteger(), nullable=False),
        sa.Column("compacted_by", sa.BigInteger(), nullable=True),
        sa.Column(
            "received_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        # Inline rather than a follow-up ALTER: SQLite cannot add a constraint
        # after the fact, and this migration is exercised on SQLite.
        sa.UniqueConstraint(
            "workspace_id",
            "author_member_id",
            "op_id",
            name="uq_ops_workspace_author_op_id",
        ),
    )
    op.create_index("ix_ops_workspace_seq", "ops", ["workspace_id", "seq"])
    op.create_index(
        "ix_ops_workspace_author_seq", "ops", ["workspace_id", "author_member_id", "author_seq"]
    )


def downgrade() -> None:
    op.drop_index("ix_ops_workspace_author_seq", table_name="ops")
    op.drop_index("ix_ops_workspace_seq", table_name="ops")
    op.drop_table("ops")
    op.drop_index("ix_members_user_id", table_name="members")
    op.drop_table("members")
