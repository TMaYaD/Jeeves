"""Add the recovery escrow, its fetch audit, and the identity columns (issue #548).

Revision ID: 0032
Revises: 0031
Create Date: 2026-07-28

Purely additive.  Two new tables — ``recovery_escrows`` (one passphrase-wrapped
Root per ``(workspace, user)`` slot) and the append-only ``recovery_escrow_fetches``
audit — plus three nullable columns: ``members.kex_pk`` and ``members.chained_at``
for ADR-0028's Root chain, and ``refresh_tokens.member_id`` for member-scoped
transport credentials.  Nothing is dropped and no existing row changes.

Every added column is nullable rather than backfilled: a Member registered
before this revision genuinely has no KEX key and genuinely is not chained to
Root, and a refresh token issued before it genuinely is a user session.  A
default would assert something untrue about existing data.

Neither new table joins the PowerSync publication — the op log and its identity
tables are the *replacement* for that replication path, not participants in it.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0032"
down_revision: str | None = "0031"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("members", sa.Column("kex_pk", sa.LargeBinary(), nullable=True))
    op.add_column("members", sa.Column("chained_at", sa.DateTime(timezone=True), nullable=True))

    # SQLite cannot add a foreign key after the fact, and this migration is
    # exercised on SQLite, so the constraint is named inline in the batch op.
    with op.batch_alter_table("refresh_tokens") as batch:
        batch.add_column(sa.Column("member_id", sa.Uuid(), nullable=True))
        batch.create_foreign_key(
            "fk_refresh_tokens_member_id",
            "members",
            ["member_id"],
            ["member_id"],
            ondelete="CASCADE",
        )
    op.create_index("ix_refresh_tokens_member_id", "refresh_tokens", ["member_id"])

    op.create_table(
        "recovery_escrows",
        sa.Column("workspace_id", sa.Uuid(), primary_key=True),
        sa.Column(
            "user_id",
            sa.String,
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        # Strictly increasing per slot: a passphrase change re-wraps at v+1 and
        # the server refuses anything at or below what it holds.
        #
        # The SQLite variant mirrors ``models.py``: these tables are exercised on
        # SQLite, where BIGINT is not a rowid alias, so migration and ORM have to
        # declare the same type or the schema the tests run against is not the
        # schema the ORM describes.
        sa.Column(
            "version",
            sa.BigInteger().with_variant(sa.Integer, "sqlite"),
            nullable=False,
        ),
        sa.Column("blob", sa.LargeBinary(), nullable=False),
        sa.Column("root_sig", sa.LargeBinary(), nullable=False),
        # Established by the first write and never changed by a later one: this
        # column is what stops a stolen user credential overwriting the escrow.
        sa.Column("root_pk", sa.LargeBinary(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )

    op.create_table(
        "recovery_escrow_fetches",
        # ``INTEGER PRIMARY KEY AUTOINCREMENT`` on SQLite — a BIGINT primary key
        # there is not a rowid alias and so does not autoincrement at all.
        sa.Column(
            "id",
            sa.BigInteger().with_variant(sa.Integer, "sqlite"),
            primary_key=True,
            autoincrement=True,
        ),
        sa.Column("workspace_id", sa.Uuid(), nullable=False),
        sa.Column(
            "user_id",
            sa.String,
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column(
            "fetched_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_index(
        "ix_recovery_escrow_fetches_user",
        "recovery_escrow_fetches",
        ["user_id", "fetched_at"],
    )


def downgrade() -> None:
    # Irreversible, same mechanism as 0031: dropping ``recovery_escrows`` destroys
    # the passphrase-recovery blob — for a User with no enrolled device left, that
    # blob *is* the account, and no client can re-upload what only the escrow
    # held.  Dropping ``members.kex_pk``/``chained_at`` and the member binding on
    # ``refresh_tokens`` would sever live sessions from the identities the op log
    # verifies against.  Fail loudly BEFORE touching any schema; recovery is a
    # restore-from-backup + ``alembic stamp``, not a downgrade.
    raise RuntimeError(
        "Migration 0032 (add_identity_root_escrow) is irreversible: dropping "
        "recovery_escrows would destroy the passphrase-recovery blob that is "
        "the only way back into an account with no enrolled device. Restore "
        "from a backup and `alembic stamp` the target revision instead of "
        "running `alembic downgrade`."
    )
