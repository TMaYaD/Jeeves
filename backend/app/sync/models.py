"""Storage for the content-blind op log.

Two tables and nothing domain-shaped: an append-only ``ops`` log per Workspace,
and a stub ``members`` registry of public keys.  Neither changes when the domain
model does — that is the whole point of ADR-0026.
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
    """A Member's registered signing key.

    Enrolment only: a row here confers **no authority**.  #548 adds the
    Root-signed MemberRegister control op that makes membership mean something;
    until then this is the proposal's ``POST /members`` row verbatim — pubkeys
    and nothing else — and clients verifying against it are knowingly trusting
    the server (review F1, accepted for pre-launch dev data).
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
        Index("ix_ops_workspace_seq", "workspace_id", "seq"),
        Index("ix_ops_workspace_author_seq", "workspace_id", "author_member_id", "author_seq"),
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
