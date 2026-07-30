"""The ``plaintext_v1`` op payload format and its hybrid logical clock.

This is a *format* definition, not server behaviour: the server is content-blind
and no route in ``app.sync.routes`` imports this module.  It exists because the
format is protocol identity — the golden-vector generator writes payloads with
it, the codec tests round-trip them, and ``app/lib/sync/op_payload.dart``
mirrors it field for field.

::

    {
      "collection": "user_preferences",
      "id": "<entity uuid>",
      "fields": {"<field>": {"v": <json>, "hlc": [wall_ms, counter, "<hex32>"]?}},
      "hlc": [wall_ms, counter, "<hex32>"],
      "tombstone": true?,
      "tombstone_hlc": [wall_ms, counter, "<hex32>"]?
    }

A field's ``hlc`` is optional and defaults to the op-level one.  Only compaction
ops (#555) populate it per field, re-asserting the original authors' clocks —
which is exactly why the reducer's sanity guards are scoped to the op-level HLC
and never to per-field HLCs (review F15, as ruled for this slice).

``tombstone_hlc`` is the same idea one level up, and it is **fenced to class 4**
by :func:`guard_op_class_shape`: a compacted tombstone has to be re-asserted at
its *original* clock, because one re-stamped with the compactor's newer clock
would bury a resurrection the original could never have buried.  Outside class 4
the field is refused rather than ignored, so the format stays unambiguous.
"""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass, field
from typing import Any, Final

from app.sync.envelope import OP_CLASS_COMPACTION

#: A member id inside an HLC is exactly 32 lowercase hex characters — the
#: 16-byte member UUID with no dashes.  The HLC tie-break is a lexicographic
#: string compare, so casing and dashes are semantics, not style: codecs reject
#: anything else rather than normalising it.
MEMBER_ID_HEX_PATTERN: Final = re.compile(r"^[0-9a-f]{32}$")

#: An entity ``id`` is a canonical lowercase UUID: 8-4-4-4-12 hex digits.
#: ``uuid.UUID`` on its own is far more permissive — it strips braces, a
#: ``urn:uuid:`` prefix and dashes wherever they fall — and the Dart codec's
#: ``uuidToBytes`` is not, so parsing with it alone would leave the two codecs
#: disagreeing about which payloads are legal.  A disagreement there is a
#: convergence bug (one device applies an op its peer quarantines), so the shape
#: is pinned here and mirrored in ``app/lib/sync/op_payload.dart``.
CANONICAL_UUID_PATTERN: Final = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)


class MalformedPayloadError(Exception):
    """A body that framed correctly but is not a well-formed op payload."""

    reason: str = "malformed_payload"


class MalformedMemberIdHexError(MalformedPayloadError):
    reason = "malformed_member_id_hex"


class CompactionFieldWithoutHlcError(MalformedPayloadError):
    """A class-4 field that carries no clock of its own.

    It would be stamped with the compactor's op-level clock and win merges the op
    it supersedes would have lost — the exact bug entity-level compaction has to
    not have.  An HLC names its author, so a field's own clock *is* its authorship
    provenance; a class-4 field without one has thrown that away.
    """

    reason = "compaction_field_without_hlc"


class CompactionTombstoneWithoutHlcError(MalformedPayloadError):
    reason = "compaction_tombstone_without_hlc"


class TombstoneHlcOutsideCompactionError(MalformedPayloadError):
    """``tombstone_hlc`` on anything but a compaction op.

    Refused rather than ignored: a permitted-and-ignored field is one a future
    reader may start honouring, and two codecs that disagree about whether it
    counts is a convergence bug.
    """

    reason = "tombstone_hlc_outside_compaction"


@dataclass(frozen=True, slots=True, order=True)
class Hlc:
    """``(wall_ms, counter, member_id)``, compared as a tuple in that order."""

    wall_ms: int
    counter: int
    member_id_hex: str

    def __post_init__(self) -> None:
        if not MEMBER_ID_HEX_PATTERN.match(self.member_id_hex):
            raise MalformedMemberIdHexError(
                f"member id {self.member_id_hex!r} is not 32 lowercase hex characters"
            )

    @classmethod
    def for_member(cls, member_id: uuid.UUID, wall_ms: int, counter: int = 0) -> Hlc:
        return cls(wall_ms=wall_ms, counter=counter, member_id_hex=member_id.hex)

    @classmethod
    def from_json(cls, raw: Any) -> Hlc:
        if not isinstance(raw, list) or len(raw) != 3:
            raise MalformedPayloadError("hlc must be a 3-element array")
        wall_ms, counter, member_id_hex = raw
        if not isinstance(wall_ms, int) or isinstance(wall_ms, bool):
            raise MalformedPayloadError("hlc wall_ms must be an integer")
        if not isinstance(counter, int) or isinstance(counter, bool):
            raise MalformedPayloadError("hlc counter must be an integer")
        if not isinstance(member_id_hex, str):
            raise MalformedMemberIdHexError("hlc member id must be a string")
        return cls(wall_ms=wall_ms, counter=counter, member_id_hex=member_id_hex)

    def to_json(self) -> list[Any]:
        return [self.wall_ms, self.counter, self.member_id_hex]


@dataclass(frozen=True, slots=True)
class FieldWrite:
    """One field's new value, optionally carrying its own (older) HLC."""

    value: Any
    hlc: Hlc | None = None


@dataclass(frozen=True, slots=True)
class OpPayload:
    collection: str
    entity_id: uuid.UUID
    hlc: Hlc
    fields: dict[str, FieldWrite] = field(default_factory=dict)
    tombstone: bool = False
    #: The clock a *compacted* tombstone is re-asserted at — the original one, not
    #: the compactor's.  Class 4 only; see :func:`guard_op_class_shape`.
    tombstone_hlc: Hlc | None = None

    @property
    def effective_tombstone_hlc(self) -> Hlc:
        """The clock the tombstone applies at: its own if it carries one, else the op's."""
        return self.hlc if self.tombstone_hlc is None else self.tombstone_hlc

    def to_json_dict(self) -> dict[str, Any]:
        fields_json: dict[str, Any] = {}
        for name, write in self.fields.items():
            entry: dict[str, Any] = {"v": write.value}
            if write.hlc is not None:
                entry["hlc"] = write.hlc.to_json()
            fields_json[name] = entry
        payload: dict[str, Any] = {
            "collection": self.collection,
            "id": str(self.entity_id),
            "fields": fields_json,
            "hlc": self.hlc.to_json(),
        }
        if self.tombstone:
            payload["tombstone"] = True
        if self.tombstone_hlc is not None:
            payload["tombstone_hlc"] = self.tombstone_hlc.to_json()
        return payload

    def encode(self) -> bytes:
        """UTF-8 JSON.  There is no canonical-JSON requirement: the signed
        artifact is the serialized body bytes, and receivers parse them, never
        re-serialize to verify."""
        return json.dumps(self.to_json_dict(), separators=(",", ":")).encode("utf-8")

    @classmethod
    def decode(cls, payload: bytes) -> OpPayload:
        try:
            raw = json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MalformedPayloadError("payload is not UTF-8 JSON") from exc
        if not isinstance(raw, dict):
            raise MalformedPayloadError("payload must be a JSON object")

        collection = raw.get("collection")
        if not isinstance(collection, str) or not collection:
            raise MalformedPayloadError("collection must be a non-empty string")

        raw_id = raw.get("id")
        if not isinstance(raw_id, str) or not CANONICAL_UUID_PATTERN.match(raw_id):
            raise MalformedPayloadError("id must be a canonical lowercase UUID string")
        entity_id = uuid.UUID(raw_id)

        # `if x is None` rather than a `.get` default, because the Dart codec this
        # module mirrors writes `raw['fields'] ?? {}` — which substitutes for an
        # explicit `null` as well as for a missing key.  A `.get` default only
        # covers the missing key, so `{"fields": null}` would be accepted by one
        # codec and refused by the other: one device applying an op its peer
        # quarantines.  Same for `tombstone` below.
        raw_fields = raw.get("fields")
        if raw_fields is None:
            raw_fields = {}
        if not isinstance(raw_fields, dict):
            raise MalformedPayloadError("fields must be an object")
        fields: dict[str, FieldWrite] = {}
        for name, entry in raw_fields.items():
            if not isinstance(entry, dict) or "v" not in entry:
                raise MalformedPayloadError(f"field {name!r} must be an object with 'v'")
            field_hlc = Hlc.from_json(entry["hlc"]) if "hlc" in entry else None
            fields[name] = FieldWrite(value=entry["v"], hlc=field_hlc)

        tombstone = raw.get("tombstone")
        if tombstone is None:
            tombstone = False
        if not isinstance(tombstone, bool):
            raise MalformedPayloadError("tombstone must be a boolean")

        # Same `is None` treatment the two fields above get, for the same reason:
        # the Dart codec reads a missing key and an explicit `null` alike, so a
        # `.get` default here would leave the two codecs disagreeing about
        # `{"tombstone_hlc": null}`.
        raw_tombstone_hlc = raw.get("tombstone_hlc")
        tombstone_hlc = None if raw_tombstone_hlc is None else Hlc.from_json(raw_tombstone_hlc)

        return cls(
            collection=collection,
            entity_id=entity_id,
            hlc=Hlc.from_json(raw.get("hlc")),
            fields=fields,
            tombstone=tombstone,
            tombstone_hlc=tombstone_hlc,
        )


def guard_op_class_shape(payload: OpPayload, *, op_class: int) -> None:
    """The class-4 shape rules, and the fence that keeps them out of every other class.

    Applied between decode and reduce on receive, and again before anything is
    signed at authoring — one function on both sides of that boundary, so an op no
    receiver would apply can never reach an outbox.

    The server never runs this on a POST: a class-4 body is ciphertext once the
    Workspace is keyed, so the rule is codec parity and vector surface rather than
    a route gate.  That is not a weakening — every *receiver* enforces it, which is
    where a payload's semantics have always been decided.
    """
    if op_class != OP_CLASS_COMPACTION:
        if payload.tombstone_hlc is not None:
            raise TombstoneHlcOutsideCompactionError(
                f"op_class {op_class} carries tombstone_hlc, which is class-4 only"
            )
        return
    for name, write in payload.fields.items():
        if write.hlc is None:
            raise CompactionFieldWithoutHlcError(
                f"compaction field {name!r} carries no hlc of its own"
            )
    if payload.tombstone and payload.tombstone_hlc is None:
        raise CompactionTombstoneWithoutHlcError(
            "a compacted tombstone must be re-asserted at its original clock"
        )
