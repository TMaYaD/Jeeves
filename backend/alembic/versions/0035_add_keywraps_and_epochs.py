"""Add the keywraps and workspace_epochs tables (issue #554).

Revision ID: 0035
Revises: 0034
Create Date: 2026-07-30

Purely additive.  Two new tables and no change to anything existing, which is what
makes turning encryption on a per-Workspace ceremony rather than a deploy: a
``plaintext_v1`` client keeps working byte for byte after this migration, and stays
working until an owner runs a rotation.

``keywraps`` holds one Workspace epoch key per ``(Workspace, Member, epoch)``,
sealed to that Member's registered X25519 key.  ``workspace_epochs`` holds one row
per ``(Workspace, epoch)`` — the materialised index of ``rotate`` control ops, the
``keywrap_digest`` those ops committed to, and the same epoch key wrapped under the
User's ``master_wrap_key``.

**The server can unwrap none of it.**  Both blobs are opaque; an operator holding
the whole of both tables gains nothing, which is the property that makes storing
them acceptable at all.  ``workspace_epochs`` exists so a wraps PUT can be checked
against the digest the signed log already committed to, and so a content POST naming
an epoch the Workspace has rotated well past can be refused, both without walking
the log per request.

Like ``workspaces`` and ``grants``, these are **materialised indexes and
authoritative for nobody** (ADR-0028) — with one distinction worth stating: a Grant
is a claim about authority the log settles, whereas a KeyWrap is a delivery of bytes
whose correctness the receiving client checks cryptographically when it opens it.
The commitment that the *set* is the right set lives in the ``rotate`` op's digest,
never in these rows.

There is no "current epoch" column anywhere.  The current epoch is
``MAX(workspace_epochs.epoch)``; a stored copy would be a cache of that maximum,
free to disagree with it.

Neither table joins the PowerSync publication — the op log and its control plane are
the *replacement* for that replication path, not participants in it.
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0035"
down_revision: str | None = "0034"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "keywraps",
        sa.Column("workspace_id", sa.Uuid(), nullable=False),
        sa.Column("member_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("kex_key_id", sa.LargeBinary(), nullable=False),
        sa.Column("wrap", sa.LargeBinary(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        # One wrap per member per epoch.  The key is also the lookup
        # ``GET /w/{w}/keywraps/me`` runs — a member fetching its own wraps across
        # every epoch is a prefix scan of this index, so no second one is needed.
        sa.PrimaryKeyConstraint("workspace_id", "member_id", "epoch", name="pk_keywraps"),
    )
    op.create_table(
        "workspace_epochs",
        sa.Column("workspace_id", sa.Uuid(), nullable=False),
        sa.Column("epoch", sa.Integer(), nullable=False),
        sa.Column("keywrap_digest", sa.LargeBinary(), nullable=False),
        sa.Column("escrow_wrap", sa.LargeBinary(), nullable=False),
        # Null for epoch 0, which no rotate op creates: a Workspace keyed from
        # genesis has its epoch 0 row minted by the first wraps PUT.
        sa.Column("rotate_seq", sa.BigInteger(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("workspace_id", "epoch", name="pk_workspace_epochs"),
    )


def downgrade() -> None:
    # Irreversible, same mechanism as 0031 and 0033 — and here the stakes are the
    # user's data rather than the server's index.  Dropping ``keywraps`` and
    # ``workspace_epochs`` destroys every copy of every Workspace content key the
    # server holds, and nothing can rebuild them: the keys are random, never
    # derived, and the plaintext exists nowhere on this side.  Every ``aead_v1`` op
    # in the log becomes permanently unreadable for any device that has not already
    # cached the epoch key locally — which, for a device enrolling afterwards, is
    # all of them.  Fail loudly BEFORE touching any schema.
    raise RuntimeError(
        "Migration 0035 (add_keywraps_and_epochs) is irreversible: dropping "
        "keywraps and workspace_epochs would destroy every server-held copy of "
        "every Workspace content key, making all aead_v1 history unreadable to any "
        "device that enrols afterwards. Restore from a backup and `alembic stamp` "
        "the target revision instead of running `alembic downgrade`."
    )
