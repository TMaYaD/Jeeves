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
        # Every BIGINT here carries the same SQLite variant its ORM column does
        # (``app/sync/models.py``).  These tables are exercised through SQLite, and
        # SQLite only gives a column rowid-autoincrement behaviour when it is
        # declared ``INTEGER PRIMARY KEY`` — a plain BIGINT primary key is a
        # different column type there, so a migration that omits the variant builds
        # a schema the ORM would not have.
        sa.Column(
            "seq",
            sa.BigInteger().with_variant(sa.Integer, "sqlite"),
            primary_key=True,
            autoincrement=True,
        ),
        sa.Column("workspace_id", sa.Uuid(), nullable=False),
        sa.Column("envelope", sa.LargeBinary(), nullable=False),
        sa.Column("op_class", sa.SmallInteger(), nullable=False),
        sa.Column("key_epoch", sa.Integer(), nullable=False),
        sa.Column("op_id", sa.Uuid(), nullable=False),
        sa.Column("author_member_id", sa.Uuid(), nullable=False),
        sa.Column("author_key_id", sa.LargeBinary(), nullable=False),
        sa.Column(
            "author_seq",
            sa.BigInteger().with_variant(sa.Integer, "sqlite"),
            nullable=False,
        ),
        sa.Column(
            "compacted_by",
            sa.BigInteger().with_variant(sa.Integer, "sqlite"),
            nullable=True,
        ),
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
        # The author chain, enforced rather than merely indexed: two concurrent
        # POSTs can both read the same MAX(author_seq) and both claim the next
        # slot, and a forked chain cannot be repaired afterwards.  Its index
        # also serves that MAX lookup, so no separate index is created.
        sa.UniqueConstraint(
            "workspace_id",
            "author_member_id",
            "author_seq",
            name="uq_ops_workspace_author_seq",
        ),
    )
    op.create_index("ix_ops_workspace_seq", "ops", ["workspace_id", "seq"])


def downgrade() -> None:
    # Irreversible: dropping ``ops`` destroys every synced envelope — the op log
    # *is* the history, and the client's own copy is not a server backup — and
    # dropping ``members`` destroys the public keys every one of those envelopes
    # is verified against, so even a restored log would be unverifiable.  Fail
    # loudly BEFORE touching any schema rather than silently lose it.  Recovery is
    # a restore-from-backup + ``alembic stamp``, not a downgrade.
    raise RuntimeError(
        "Migration 0031 (add_sync_op_log) is irreversible: dropping the ops "
        "table would destroy every synced envelope, and dropping members would "
        "destroy the keys those envelopes are verified against. Restore from a "
        "backup and `alembic stamp` the target revision instead of running "
        "`alembic downgrade`."
    )
