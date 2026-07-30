"""The class-5 prune payload: what a compaction supersedes, and its proof.

Mirrored field for field by ``app/lib/sync/prune_payload.dart`` and pinned by
``spec/sync/envelope_v1_vectors.json``.

::

    {
      "compaction": {"op_id": "<uuid>"},
      "targets": [
        {
          "seq": <transport seq>,
          "author_member_id": "<uuid>",
          "author_seq": <n>,
          "envelope_hash": "<hex64>"
        }
      ]
    }

**Why a target is more than a seq** (ADR-0035).  The proposal says a prune
"enumerates the seqs its compaction supersedes", and a transport seq is not
enough, because of a structural fact about entity-level compaction: an author's
chain interleaves many entities' ops, so pruning one entity's ops removes
positions *inside* every contributing author's chain rather than truncating a
prefix.  A fresh device verifying a survivor at ``author_seq N`` needs to know
that ``head+1 .. N-1`` were legitimately removed **and** the envelope hash at
``N-1`` to check ``prev_author_hash`` against.  The attestation carries both.

**Server-readable by design**, which is why prune ops are ``plaintext_v1`` for
ever (``encrypted_prune_op``): the server acts on this payload to stamp
``ops.compacted_by``, and it can afford to read it because the enumeration is
content-free — seqs, author positions and hashes, and nothing about what any op
said.  This is the second deliberate exception to content-blindness, the first
being control ops.

Three rules are **shape** rules, refused at decode wherever the bytes are held
rather than at any one route: an empty enumeration, a duplicate target, and more
targets than one op may carry.  Refusing duplicates here is what leaves the
server's materialisation rowcount check exactly one possible cause — a concurrent
prune — so a race can never be misreported as a malformed payload or the reverse.
"""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass
from typing import Any, Final

from app.sync.envelope import PREV_AUTHOR_HASH_BYTES
from app.sync.op_payload import CANONICAL_UUID_PATTERN

#: An envelope hash is exactly 64 lowercase hex characters — SHA-256 of the whole
#: envelope, spelled the way :mod:`app.sync.op_payload` spells a member id: one
#: casing, no normalisation, because a codec that accepted another spelling would
#: accept attestations its peer refuses.
ENVELOPE_HASH_HEX_PATTERN: Final = re.compile(r"^[0-9a-f]{64}$")

#: not configurable: how many ops one prune may attest.  It bounds the single
#: ``UPDATE`` the server runs and the walk every client runs, and it is the same
#: order of magnitude as ``MAX_OPS_PER_BATCH`` because a compaction pass that
#: needed more than this is one that should be split.
MAX_PRUNE_TARGETS: Final = 1000


class PrunePayloadError(Exception):
    """A body that framed correctly but is not a well-formed prune payload."""

    reason: str = "malformed_prune_payload"


class PruneTargetsEmptyError(PrunePayloadError):
    """A prune that attests nothing.

    It materialises nothing and can only exist to spend a chain slot or confuse an
    audit, so it is refused at the shape level where both codecs agree rather than
    accepted and then found to be a no-op.
    """

    reason = "prune_targets_empty"


class PruneDuplicateTargetError(PrunePayloadError):
    """Two entries sharing a ``seq`` **or** an ``(author, author_seq)`` position.

    Both keys, independently: either duplication would make the materialisation
    rowcount disagree with the target count, which is the signal reserved for a
    concurrent prune.
    """

    reason = "prune_duplicate_target"


class PruneTargetsTooManyError(PrunePayloadError):
    reason = "prune_targets_too_many"


@dataclass(frozen=True, slots=True)
class PruneTarget:
    """One superseded op, attested well enough to chain past it.

    ``envelope_hash`` is what a verifier needs and ``seq`` is what the server
    needs; ``author_member_id``/``author_seq`` are what tie the two together, and
    the server cross-checks all four against the envelope it holds before it
    stamps anything.
    """

    seq: int
    author_member_id: uuid.UUID
    author_seq: int
    envelope_hash: bytes

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "seq": self.seq,
            "author_member_id": str(self.author_member_id),
            "author_seq": self.author_seq,
            "envelope_hash": self.envelope_hash.hex(),
        }

    @classmethod
    def from_json(cls, raw: Any) -> PruneTarget:
        if not isinstance(raw, dict):
            raise PrunePayloadError("a prune target must be a JSON object")
        seq = raw.get("seq")
        if not isinstance(seq, int) or isinstance(seq, bool) or seq <= 0:
            raise PrunePayloadError("a prune target's seq must be a positive integer")
        author_member_id = raw.get("author_member_id")
        if not isinstance(author_member_id, str) or not CANONICAL_UUID_PATTERN.match(
            author_member_id
        ):
            raise PrunePayloadError(
                "a prune target's author_member_id must be a canonical lowercase UUID"
            )
        author_seq = raw.get("author_seq")
        if not isinstance(author_seq, int) or isinstance(author_seq, bool) or author_seq <= 0:
            raise PrunePayloadError("a prune target's author_seq must be a positive integer")
        envelope_hash = raw.get("envelope_hash")
        if not isinstance(envelope_hash, str) or not ENVELOPE_HASH_HEX_PATTERN.match(envelope_hash):
            raise PrunePayloadError(
                f"a prune target's envelope_hash must be "
                f"{PREV_AUTHOR_HASH_BYTES * 2} lowercase hex characters"
            )
        return cls(
            seq=seq,
            author_member_id=uuid.UUID(author_member_id),
            author_seq=author_seq,
            envelope_hash=bytes.fromhex(envelope_hash),
        )


@dataclass(frozen=True, slots=True)
class PrunePayload:
    """The compaction this prune stands behind, and every op it supersedes."""

    compaction_op_id: uuid.UUID
    targets: tuple[PruneTarget, ...]

    def to_json_dict(self) -> dict[str, Any]:
        return {
            "compaction": {"op_id": str(self.compaction_op_id)},
            "targets": [target.to_json_dict() for target in self.targets],
        }

    def encode(self) -> bytes:
        """Shape-checked on the way out as well as in.

        Authoring goes through the same rules a receiver applies, so a prune no
        peer would accept is never signed — the discipline ``capture()`` follows
        for content payloads.
        """
        require_prune_shape(self.targets)
        return json.dumps(self.to_json_dict(), separators=(",", ":")).encode("utf-8")

    @classmethod
    def decode(cls, payload: bytes) -> PrunePayload:
        try:
            raw = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise PrunePayloadError("prune payload is not UTF-8 JSON") from exc
        if not isinstance(raw, dict):
            raise PrunePayloadError("prune payload must be a JSON object")

        compaction = raw.get("compaction")
        if not isinstance(compaction, dict):
            raise PrunePayloadError("prune payload must name its compaction op")
        compaction_op_id = compaction.get("op_id")
        if not isinstance(compaction_op_id, str) or not CANONICAL_UUID_PATTERN.match(
            compaction_op_id
        ):
            raise PrunePayloadError("compaction.op_id must be a canonical lowercase UUID string")

        raw_targets = raw.get("targets")
        if not isinstance(raw_targets, list):
            raise PrunePayloadError("targets must be an array")
        targets = tuple(PruneTarget.from_json(entry) for entry in raw_targets)
        require_prune_shape(targets)
        return cls(compaction_op_id=uuid.UUID(compaction_op_id), targets=targets)


def require_prune_shape(targets: tuple[PruneTarget, ...]) -> None:
    """The three shape rules, in the order a reader hits them."""
    if not targets:
        raise PruneTargetsEmptyError("a prune must attest at least one op")
    if len(targets) > MAX_PRUNE_TARGETS:
        raise PruneTargetsTooManyError(
            f"a prune may attest at most {MAX_PRUNE_TARGETS} ops, not {len(targets)}"
        )
    seqs = {target.seq for target in targets}
    if len(seqs) != len(targets):
        raise PruneDuplicateTargetError("two prune targets name one transport seq")
    positions = {(target.author_member_id, target.author_seq) for target in targets}
    if len(positions) != len(targets):
        raise PruneDuplicateTargetError("two prune targets name one author position")
