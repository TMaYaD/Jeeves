"""The Python codec against the frozen golden vectors.

``app/test/sync/envelope_vectors_test.dart`` runs the same assertions against
the same file.  Two independent implementations agreeing byte-for-byte with a
committed artifact is what keeps the Dart harness's in-process server double
honest about the wire format the real server speaks.
"""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from nacl.signing import SigningKey

from app.sync import envelope as env
from app.sync.envelope import EnvelopeError, OpHeader
from app.sync.ids import (
    JEEVES_WORKSPACE_NAMESPACE,
    implicit_workspace_id,
    preference_entity_id,
)
from app.sync.op_payload import MalformedPayloadError, OpPayload
from tests.sync.vectors import envelope_vectors

_DOCUMENT = envelope_vectors()
_PROTOCOL = _DOCUMENT["protocol"]
_IDENTITIES = _DOCUMENT["identities"]
_KEYS_BY_LABEL = {entry["label"]: entry for entry in _IDENTITIES["keys"]}


def _header_from_json(raw: dict[str, Any]) -> OpHeader:
    return OpHeader(
        suite=raw["suite"],
        op_class=raw["op_class"],
        workspace_id=uuid.UUID(raw["workspace_id"]),
        key_epoch=raw["key_epoch"],
        op_id=uuid.UUID(raw["op_id"]),
        author_member_id=uuid.UUID(raw["author_member_id"]),
        author_key_id=bytes.fromhex(raw["author_key_id_hex"]),
        author_seq=raw["author_seq"],
        prev_author_hash=bytes.fromhex(raw["prev_author_hash_hex"]),
        observed_head=bytes.fromhex(raw["observed_head_hex"]),
        nonce=bytes.fromhex(raw["nonce_hex"]),
    )


def _receive(envelope: bytes, expected_workspace_id: uuid.UUID, sign_pk: bytes) -> OpPayload:
    """The receiving client's fail-closed pipeline, in its normative order.

    The real server never runs this — it is content-blind and stops after the
    header.  The Dart client runs the identical sequence in
    ``sync_client.dart``; both are pinned to the same ``reason`` codes by the
    negative vectors, which is what stops the two from drifting apart.
    """
    header_bytes, body, _signature = env.split_envelope(envelope)
    header = OpHeader.parse(header_bytes)
    env.check_served(header)
    if header.workspace_id != expected_workspace_id:
        raise env.WorkspaceMismatchError("header workspace is not the pulled workspace")
    env.verify_envelope(envelope, sign_pk)
    return OpPayload.decode(env.parse_body(body))


def test_protocol_constants_match_the_frozen_file() -> None:
    assert _PROTOCOL["header_length_bytes"] == env.HEADER_LENGTH_BYTES
    assert _PROTOCOL["signature_length_bytes"] == env.SIGNATURE_LENGTH_BYTES
    assert _PROTOCOL["envelope_overhead_bytes"] == env.ENVELOPE_OVERHEAD_BYTES
    assert _PROTOCOL["signing_domain"] == env.SIGNING_DOMAIN_OP_V1.decode("ascii")
    assert _PROTOCOL["suites"]["plaintext_v1"] == env.SUITE_PLAINTEXT_V1
    assert _PROTOCOL["suites"]["aead_v1_reserved"] == env.SUITE_AEAD_V1
    assert _PROTOCOL["served_suites"] == sorted(env.SERVED_SUITES)
    assert _PROTOCOL["served_op_classes"] == sorted(env.SERVED_OP_CLASSES)
    assert _PROTOCOL["known_op_classes"] == sorted(env.KNOWN_OP_CLASSES)
    assert _PROTOCOL["body_size_classes_bytes"] == list(env.BODY_SIZE_CLASSES_BYTES)
    assert _PROTOCOL["body_oversize_multiple_bytes"] == env.BODY_OVERSIZE_MULTIPLE_BYTES
    assert _PROTOCOL["payload_length_prefix_bytes"] == env.PAYLOAD_LENGTH_PREFIX_BYTES
    assert _PROTOCOL["workspace_namespace_uuid"] == str(JEEVES_WORKSPACE_NAMESPACE)
    assert [
        (entry["name"], entry["offset"], entry["length_bytes"])
        for entry in _PROTOCOL["header_field_layout"]
    ] == list(env.HEADER_FIELD_LAYOUT)


def test_header_field_layout_sums_to_the_header_length() -> None:
    layout = _PROTOCOL["header_field_layout"]
    assert sum(entry["length_bytes"] for entry in layout) == env.HEADER_LENGTH_BYTES
    running_offset = 0
    for entry in layout:
        assert entry["offset"] == running_offset, entry["name"]
        running_offset += entry["length_bytes"]


def test_derived_identities_match_the_frozen_file() -> None:
    workspace_id = implicit_workspace_id(_IDENTITIES["user_id"])
    assert str(workspace_id) == _IDENTITIES["workspace_id"]
    assert (
        str(implicit_workspace_id(_IDENTITIES["other_user_id"]))
        == (_IDENTITIES["other_workspace_id"])
    )
    assert (
        str(preference_entity_id(workspace_id, _IDENTITIES["preference_key"]))
        == (_IDENTITIES["preference_entity_id"])
    )


def test_key_ids_are_derived_from_the_public_keys() -> None:
    for entry in _IDENTITIES["keys"]:
        signing_key = SigningKey(bytes.fromhex(entry["seed_hex"]))
        sign_pk = bytes(signing_key.verify_key)
        assert sign_pk.hex() == entry["sign_pk_hex"]
        assert env.derive_key_id(sign_pk).hex() == entry["key_id_hex"]


@pytest.mark.parametrize("vector", _DOCUMENT["header_vectors"], ids=lambda v: str(v["name"]))
def test_header_vector_serializes_and_round_trips(vector: dict[str, Any]) -> None:
    header = _header_from_json(vector["header"])
    serialized = header.serialize()
    assert serialized.hex() == vector["header_hex"]
    assert len(serialized) == env.HEADER_LENGTH_BYTES
    assert OpHeader.parse(serialized) == header


@pytest.mark.parametrize("vector", _DOCUMENT["vectors"], ids=lambda v: str(v["name"]))
def test_positive_vector_is_byte_identical(vector: dict[str, Any]) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    signing_key = SigningKey(bytes.fromhex(key_entry["seed_hex"]))
    header = _header_from_json(vector["header"])
    payload = vector["payload_json"].encode("utf-8")

    assert header.serialize().hex() == vector["header_hex"]
    assert len(payload) == vector["payload_length_bytes"]

    body = env.frame_body(payload)
    assert len(body) == vector["body_length_bytes"]
    assert body.hex() == vector["body_hex"]

    envelope = env.build_envelope(header, body, signing_key)
    assert envelope.hex() == vector["envelope_hex"]
    assert envelope[-env.SIGNATURE_LENGTH_BYTES :].hex() == vector["signature_hex"]
    assert env.envelope_hash(envelope).hex() == vector["envelope_sha256_hex"]
    assert len(envelope) == env.ENVELOPE_OVERHEAD_BYTES + vector["body_length_bytes"]


@pytest.mark.parametrize("vector", _DOCUMENT["vectors"], ids=lambda v: str(v["name"]))
def test_positive_vector_round_trips_through_the_receive_pipeline(
    vector: dict[str, Any],
) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    envelope = bytes.fromhex(vector["envelope_hex"])
    header_bytes, body, _ = env.split_envelope(envelope)

    assert OpHeader.parse(header_bytes) == _header_from_json(vector["header"])
    assert env.parse_body(body).decode("utf-8") == vector["payload_json"]

    payload = _receive(
        envelope,
        uuid.UUID(vector["header"]["workspace_id"]),
        bytes.fromhex(key_entry["sign_pk_hex"]),
    )
    # Re-encoding is not part of verification (the signed artifact is the body
    # bytes), but a decode that loses information would silently break merges.
    assert OpPayload.decode(payload.encode()) == payload


@pytest.mark.parametrize("vector", _DOCUMENT["negative_vectors"], ids=lambda v: str(v["name"]))
def test_negative_vector_fails_closed_with_the_pinned_reason(
    vector: dict[str, Any],
) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    envelope = bytes.fromhex(vector["envelope_hex"])
    try:
        _receive(
            envelope,
            uuid.UUID(vector["expected_workspace_id"]),
            bytes.fromhex(key_entry["sign_pk_hex"]),
        )
    except (EnvelopeError, MalformedPayloadError) as rejection:
        assert rejection.reason == vector["reason"]
    else:
        pytest.fail(f"{vector['name']} was accepted; expected {vector['reason']}")


def test_non_zero_padding_vector_puts_the_byte_at_the_first_padding_position() -> None:
    """An off-by-one in the padding scan must not survive this vector."""
    vector = next(v for v in _DOCUMENT["negative_vectors"] if v["name"] == "non_zero_padding")
    _, body, _ = env.split_envelope(bytes.fromhex(vector["envelope_hex"]))
    payload_length = int.from_bytes(body[: env.PAYLOAD_LENGTH_PREFIX_BYTES], "big")
    first_padding_offset = env.PAYLOAD_LENGTH_PREFIX_BYTES + payload_length
    assert body[first_padding_offset] != 0
    assert not any(body[first_padding_offset + 1 :])


def test_body_size_class_arithmetic() -> None:
    assert env.padded_body_length(1) == 256
    assert env.padded_body_length(256) == 256
    assert env.padded_body_length(257) == 1024
    assert env.padded_body_length(16384) == 16384
    assert env.padded_body_length(16385) == 32768
    assert env.padded_body_length(32768) == 32768
    assert env.padded_body_length(32769) == 49152

    assert env.is_legal_body_length(256)
    assert env.is_legal_body_length(32768)
    assert env.is_legal_body_length(49152)
    assert not env.is_legal_body_length(0)
    assert not env.is_legal_body_length(300)
    assert not env.is_legal_body_length(16385)


def test_frame_body_round_trips_across_every_size_class_boundary() -> None:
    for payload_length in (0, 1, 251, 252, 253, 1019, 1020, 16379, 16380, 16381):
        payload = b"z" * payload_length
        body = env.frame_body(payload)
        assert env.is_legal_body_length(len(body))
        assert env.parse_body(body) == payload
