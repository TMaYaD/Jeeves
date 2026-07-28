"""Add the workspaces and grants indexes, and members.member_kind (issue #549).

Revision ID: 0033
Revises: 0032
Create Date: 2026-07-28

Purely additive.  Two new tables — ``workspaces`` (one row per Workspace whose
``workspace_genesis`` control op the server has materialised) and ``grants`` (one
row per Grant, with the transport seqs that made and unmade it) — plus one
nullable column, ``members.member_kind``.

Both tables are **materialised indexes for the server's own authorization and
authoritative for nobody** (ADR-0028).  Clients derive membership and roles from
the signed control ops in the log; these rows exist so a content POST can be
authorized without walking the log on every request.

``member_kind`` is nullable rather than defaulted to ``device``: the kind is a
*signed* fact carried by a registration certificate, and a shell row created by
``POST /members`` has no certificate behind it.  Backfilling it would be the
server asserting something no signature says.

Neither new table joins the PowerSync publication — the op log and its control
plane are the *replacement* for that replication path, not participants in it.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0033"
down_revision: str | None = "0032"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("members", sa.Column("member_kind", sa.String(), nullable=True))

    op.create_table(
        "workspaces",
        sa.Column("workspace_id", sa.Uuid(), primary_key=True),
        # The seq of the genesis op, so the row is always traceable back to the
        # evidence that produced it.
        sa.Column("genesis_seq", sa.BigInteger(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )

    op.create_table(
        "grants",
        sa.Column("workspace_id", sa.Uuid(), primary_key=True),
        sa.Column("grant_id", sa.Uuid(), primary_key=True),
        sa.Column("member_id", sa.Uuid(), nullable=False),
        # owner | participant | compactor | suggester, verbatim from the cert.
        sa.Column("role", sa.String(), nullable=False),
        # "root" or the granting Member's id.
        sa.Column("granter", sa.String(), nullable=False),
        sa.Column("granted_seq", sa.BigInteger(), nullable=False),
        # Null while the Grant is live.  Liveness is evaluated *at* an op's seq,
        # never against current state, so both bounds have to be recorded.
        sa.Column("revoked_by_seq", sa.BigInteger(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_index("ix_grants_workspace_member", "grants", ["workspace_id", "member_id"])


def downgrade() -> None:
    # Irreversible, same mechanism as 0031: ``workspaces`` and ``grants`` are the
    # server's authorization index over the control log, and no tool exists to
    # re-derive them from ``ops`` — dropping them leaves every content POST
    # refused and every genesis forgotten while the log itself survives.
    # ``members.member_kind`` records what a signed registration certificate
    # asserted, equally unrecoverable server-side.  Fail loudly BEFORE touching
    # any schema; recovery is a restore-from-backup + ``alembic stamp``, not a
    # downgrade.
    raise RuntimeError(
        "Migration 0033 (add_workspaces_and_grants) is irreversible: dropping "
        "workspaces and grants would destroy the server's authorization index, "
        "which nothing can rebuild from the op log. Restore from a backup and "
        "`alembic stamp` the target revision instead of running "
        "`alembic downgrade`."
    )
