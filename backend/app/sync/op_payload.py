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
      "tombstone": true?
    }

A field's ``hlc`` is optional and defaults to the op-level one.  Only compaction
ops (#555) populate it per field, re-asserting the original authors' clocks —
which is exactly why the reducer's sanity guards are scoped to the op-level HLC
and never to per-field HLCs (review F15, as ruled for this slice).
"""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass, field
from typing import Any, Final

#: A member id inside an HLC is exactly 32 lowercase hex characters — the
#: 16-byte member UUID with no dashes.  The HLC tie-break is a lexicographic
#: string compare, so casing and dashes are semantics, not style: codecs reject
#: anything else rather than normalising it.
MEMBER_ID_HEX_PATTERN: Final = re.compile(r"^[0-9a-f]{32}$")


class MalformedPayloadError(Exception):
    """A body that framed correctly but is not a well-formed op payload."""

    reason: str = "malformed_payload"


class MalformedMemberIdHexError(MalformedPayloadError):
    reason = "malformed_member_id_hex"


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
        if not isinstance(raw_id, str):
            raise MalformedPayloadError("id must be a string")
        try:
            entity_id = uuid.UUID(raw_id)
        except ValueError as exc:
            raise MalformedPayloadError("id must be a UUID") from exc

        raw_fields = raw.get("fields", {})
        if not isinstance(raw_fields, dict):
            raise MalformedPayloadError("fields must be an object")
        fields: dict[str, FieldWrite] = {}
        for name, entry in raw_fields.items():
            if not isinstance(entry, dict) or "v" not in entry:
                raise MalformedPayloadError(f"field {name!r} must be an object with 'v'")
            field_hlc = Hlc.from_json(entry["hlc"]) if "hlc" in entry else None
            fields[name] = FieldWrite(value=entry["v"], hlc=field_hlc)

        tombstone = raw.get("tombstone", False)
        if not isinstance(tombstone, bool):
            raise MalformedPayloadError("tombstone must be a boolean")

        return cls(
            collection=collection,
            entity_id=entity_id,
            hlc=Hlc.from_json(raw.get("hlc")),
            fields=fields,
            tombstone=tombstone,
        )
