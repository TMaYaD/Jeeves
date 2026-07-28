"""Storage for the op log, the Member registry and the recovery escrow.

Nothing domain-shaped: an append-only ``ops`` log per Workspace, a ``members``
registry of public keys, and the per-User ``recovery_escrows`` slot with its
append-only fetch audit.  None of them change when the domain model does — that
is the whole point of ADR-0026.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

from sqlalchemy import (
    BigInteger,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    SmallInteger,
    String,
    UniqueConstraint,
    Uuid,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class Member(Base):
    """A Member's registered public keys.

    ``POST /members`` creates the row and it confers **no authority**: an
    unchained row is a shell.  Authority arrives when a Root-signed
    MemberRegister control op lands in the log and ``chained_at`` is stamped
    (ADR-0028).  Clients do not read this table to decide anything — they
    chain-gate off the log itself — so the column is the server's own index and
    is authoritative for nobody.
    """

    __tablename__ = "members"

    member_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    user_id: Mapped[str] = mapped_column(
        String, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    #: Raw 32-byte Ed25519 public key.
    sign_pk: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    #: First 8 bytes of SHA-256(sign_pk).  **Server-derived**, never a client claim.
    key_id: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    #: Raw 32-byte X25519 public key.  Separate from the signing key (F8/F19);
    #: nullable because rows predating #548 have no KEX key and nothing reads it
    #: until #554's KeyWraps.
    kex_pk: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True)
    #: ``device`` or ``service``, materialised from the registration certificate.
    #: Nullable because a row created by ``POST /members`` has no certificate
    #: behind it yet — the kind is a *signed* fact, so the shell row cannot claim
    #: one.  The ``user_preferences`` Workspace reads it to refuse Service Grants.
    member_kind: Mapped[str | None] = mapped_column(String, nullable=True)
    #: When a Root-signed MemberRegister for this member was materialised.
    chained_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), nullable=False
    )


class Op(Base):
    """One opaque envelope, as received.

    ``envelope`` is the truth.  Every other column is a **pure index** parsed out
    of the header for the server's own content-blind authz and paging; a client
    cross-checks them against the envelope bytes and never the other way round
    (review F6).
    """

    __tablename__ = "ops"
    __table_args__ = (
        # Author-namespaced op ids: verbatim replay is a no-op, and one member
        # cannot burn another's op_id space (review F13).
        UniqueConstraint(
            "workspace_id", "author_member_id", "op_id", name="uq_ops_workspace_author_op_id"
        ),
        # One author fills each slot of their own chain exactly once.  The POST
        # handler's gap check reads MAX(author_seq) and then inserts, so two
        # concurrent batches can both read the same maximum and both believe
        # they own the next slot — a write skew no amount of application code
        # closes.  The database is the only place that can, and a forked author
        # chain is unrecoverable: `prev_author_hash` would name two successors.
        # Doubles as the index for that MAX lookup, which is why there is no
        # separate one.
        UniqueConstraint(
            "workspace_id", "author_member_id", "author_seq", name="uq_ops_workspace_author_seq"
        ),
        Index("ix_ops_workspace_seq", "workspace_id", "seq"),
    )

    #: Transport cursor and nothing else (review F20): never causality, never a
    #: merge input, never evidence.  Holes are meaningless.
    seq: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"),
        primary_key=True,
        autoincrement=True,
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    envelope: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)

    op_class: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    key_epoch: Mapped[int] = mapped_column(Integer, nullable=False)
    op_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    author_member_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    author_key_id: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    author_seq: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), nullable=False
    )

    #: Set by a prune op (#555) to the seq that supersedes this row.  v1 prunes
    #: are soft deletes: default pulls exclude these rows, nothing is deleted.
    compacted_by: Mapped[int | None] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), nullable=True
    )
    received_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), nullable=False
    )


class Workspace(Base):
    """A Workspace whose ``workspace_genesis`` control op the server has seen.

    A **materialised index, authoritative for nobody** (ADR-0028): the signed
    genesis in the log is the fact, this row is the server's own note of it.  It
    exists so a content POST into a Workspace nobody ever created can be refused
    (``workspace_not_created``) without walking the log on every request.

    There is no owner column.  Participation *is* the Grants — an owner is a
    Member holding a live ``owner`` Grant, and nothing else.
    """

    __tablename__ = "workspaces"

    workspace_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    #: The transport seq of the genesis op, so the row can always be traced back
    #: to the evidence that produced it.
    genesis_seq: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), nullable=False
    )


class Grant(Base):
    """One materialised Grant — the server's index for its own authz.

    Authoritative for nobody (ADR-0028): a client derives its grants view from
    the applied control log and never from this table, which is what makes "role
    elevation via server tables is impossible" true rather than aspirational.

    ``granted_seq``/``revoked_by_seq`` are the **transport seqs** of the control
    ops that made and unmade the Grant, and the authorization verdict is
    positional against them: an op at seq S is authorized iff
    ``granted_seq < S`` and (``revoked_by_seq`` is null or ``S < revoked_by_seq``).
    Anchoring on seq rather than on the certificate HLC is deliberate — HLC
    anchoring would let a revoked author backdate ops under the boundary.
    """

    __tablename__ = "grants"
    __table_args__ = (Index("ix_grants_workspace_member", "workspace_id", "member_id"),)

    workspace_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    grant_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    member_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    #: One of ``owner``/``participant``/``compactor``/``suggester``.
    role: Mapped[str] = mapped_column(String, nullable=False)
    #: ``root`` or the granting Member's id, verbatim from the signed cert.
    granter: Mapped[str] = mapped_column(String, nullable=False)
    granted_seq: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), nullable=False
    )
    #: Null while the Grant is live.
    revoked_by_seq: Mapped[int | None] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), nullable=False
    )


class RecoveryEscrow(Base):
    """One User's passphrase-wrapped Root, as four opaque fields.

    Keyed ``(workspace_id, user_id)``: the escrow is per-User content, and
    carrying the Workspace in the key means the shape survives shared Workspaces
    without a migration.  ``root_pk`` is what makes the slot defensible — once a
    record exists, a ``PUT`` must be signed by *that* Root, so a stolen user
    credential cannot overwrite the escrow (review F16).  ``blob`` is never
    parsed here; its layout is documented in ``app.sync.escrow`` for the
    vectors' benefit and belongs to the client.
    """

    __tablename__ = "recovery_escrows"

    workspace_id: Mapped[uuid.UUID] = mapped_column(Uuid, primary_key=True)
    user_id: Mapped[str] = mapped_column(
        String, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    #: Strictly increasing per slot.  A passphrase change is a re-wrap at v+1,
    #: and a client refuses anything below the highest version it has seen.
    version: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), nullable=False
    )
    blob: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    root_sig: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    #: Raw 32-byte Ed25519 Root public key.  Established by the first write and
    #: never changed by a later one — that is the whole point of the slot.
    root_pk: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), nullable=False
    )


class RecoveryEscrowFetch(Base):
    """Append-only audit of every escrow read.

    A silent read is the one thing an escrow attack needs; recording each one
    is what turns it into something the User can be shown.
    """

    __tablename__ = "recovery_escrow_fetches"
    __table_args__ = (Index("ix_recovery_escrow_fetches_user", "user_id", "fetched_at"),)

    id: Mapped[int] = mapped_column(
        BigInteger().with_variant(Integer, "sqlite"), primary_key=True, autoincrement=True
    )
    workspace_id: Mapped[uuid.UUID] = mapped_column(Uuid, nullable=False)
    user_id: Mapped[str] = mapped_column(
        String, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    fetched_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=lambda: datetime.now(UTC), nullable=False
    )
