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

from app.sync import control_payload as control
from app.sync import envelope as env
from app.sync import escrow as esc
from app.sync import member_auth
from app.sync.control_payload import ControlPayload, ControlPayloadError, RegistrationCertificate
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
_ROOT_PUBLIC_KEY = bytes.fromhex(_IDENTITIES["root"]["root_pk_hex"])


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


def _receive_control(envelope: bytes, root_pk: bytes) -> RegistrationCertificate:
    """The control half of the receive pipeline, in D6's normative order.

    Steps 1-5 of the six: the chain check (step 6) needs state a vector cannot
    carry, so it is pinned by the route and harness tests instead.  Note that
    the envelope-signature check runs *here*, against the certificate's key —
    for a MemberRegister the author is by definition not yet in the directory,
    which is exactly why the check defers into this path.
    """
    header_bytes, body, _signature = env.split_envelope(envelope)
    header = OpHeader.parse(header_bytes)
    env.check_served(header)
    assert header.op_class == env.OP_CLASS_CONTROL

    payload = ControlPayload.decode(env.parse_body(body))
    payload.require_served_type()
    control.verify_registration_certificate(payload.cert_bytes, payload.root_sig, root_pk)
    certificate = payload.certificate()
    if certificate.member_id != header.author_member_id:
        raise ControlPayloadError("cert_member_mismatch")
    env.verify_envelope(envelope, certificate.sign_pk)
    if env.derive_key_id(certificate.sign_pk) != header.author_key_id:
        raise ControlPayloadError("cert_key_mismatch")
    return certificate


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


# --- Control plane -----------------------------------------------------------


def test_control_constants_match_the_frozen_file() -> None:
    domains = _PROTOCOL["signing_domains"]
    assert domains["op_v1"] == env.SIGNING_DOMAIN_OP_V1.decode("ascii")
    assert domains["member_register_v1"] == control.SIGNING_DOMAIN_MEMBER_REGISTER_V1.decode(
        "ascii"
    )
    assert domains["auth_challenge_v1"] == member_auth.SIGNING_DOMAIN_AUTH_CHALLENGE_V1.decode(
        "ascii"
    )
    assert domains["escrow_v1"] == esc.SIGNING_DOMAIN_ESCROW_V1.decode("ascii")
    # Four distinct domains, or a signature made for one use would verify for
    # another (review F7).
    assert len(set(domains.values())) == len(domains)

    frozen = _PROTOCOL["control"]
    assert frozen["member_register_type"] == control.CONTROL_TYPE_MEMBER_REGISTER
    assert frozen["served_control_types"] == sorted(control.SERVED_CONTROL_TYPES)
    assert frozen["member_kind_device"] == control.MEMBER_KIND_DEVICE
    assert frozen["prev_control_hash_bytes"] == control.PREV_CONTROL_HASH_BYTES
    assert frozen["zero_prev_control_hash_hex"] == control.ZERO_PREV_CONTROL_HASH.hex()
    assert frozen["kex_public_key_bytes"] == control.KEX_PUBLIC_KEY_BYTES
    # op_class 2 is served now: that is what this slice changed about the wire.
    assert env.OP_CLASS_CONTROL in env.SERVED_OP_CLASSES


@pytest.mark.parametrize("vector", _DOCUMENT["control_vectors"], ids=lambda v: str(v["name"]))
def test_control_vector_is_byte_identical(vector: dict[str, Any]) -> None:
    key_entry = _KEYS_BY_LABEL[vector["key"]]
    signing_key = SigningKey(bytes.fromhex(key_entry["seed_hex"]))
    header = _header_from_json(vector["header"])
    payload = vector["payload_json"].encode("utf-8")

    assert header.op_class == env.OP_CLASS_CONTROL
    assert header.author_seq == 1, "a member_register is its author's first op"
    assert header.serialize().hex() == vector["header_hex"]
    assert len(payload) == vector["payload_length_bytes"]

    body = env.frame_body(payload)
    assert body.hex() == vector["body_hex"]
    envelope = env.build_envelope(header, body, signing_key)
    assert envelope.hex() == vector["envelope_hex"]
    assert env.envelope_hash(envelope).hex() == vector["envelope_sha256_hex"]

    # The chain link is over the payload bytes, never the envelope.
    assert control.control_payload_hash(payload).hex() == vector["payload_sha256_hex"]
    assert control.control_payload_hash(payload).hex() != vector["envelope_sha256_hex"]


@pytest.mark.parametrize("vector", _DOCUMENT["control_vectors"], ids=lambda v: str(v["name"]))
def test_control_vector_round_trips_through_the_receive_pipeline(
    vector: dict[str, Any],
) -> None:
    envelope = bytes.fromhex(vector["envelope_hex"])
    certificate = _receive_control(envelope, _ROOT_PUBLIC_KEY)

    key_entry = _KEYS_BY_LABEL[vector["key"]]
    assert certificate.sign_pk.hex() == key_entry["sign_pk_hex"]
    assert certificate.kex_pk.hex() == key_entry["kex_pk_hex"]
    assert str(certificate.member_id) == key_entry["member_id"]
    assert certificate.member_kind == control.MEMBER_KIND_DEVICE
    # The signed artifact is the certificate's literal bytes; re-encoding is not
    # part of verification, but a lossy decode would break every verifier.
    assert certificate.encode().decode("utf-8") == vector["cert_json"]
    assert certificate.encode().hex() == vector["cert_hex"]

    payload = ControlPayload.decode(env.parse_body(env.split_envelope(envelope)[1]))
    assert payload.prev_control_hash.hex() == vector["prev_control_hash_hex"]
    assert payload.root_sig.hex() == vector["root_sig_hex"]


def test_the_chained_control_vector_names_its_predecessors_payload_hash() -> None:
    first, chained = _DOCUMENT["control_vectors"]
    assert first["prev_control_hash_hex"] == control.ZERO_PREV_CONTROL_HASH.hex()
    assert chained["prev_control_hash_hex"] == first["payload_sha256_hex"]


@pytest.mark.parametrize(
    "vector", _DOCUMENT["negative_control_vectors"], ids=lambda v: str(v["name"])
)
def test_negative_control_vector_fails_closed_with_the_pinned_reason(
    vector: dict[str, Any],
) -> None:
    envelope = bytes.fromhex(vector["envelope_hex"])
    try:
        _receive_control(envelope, _ROOT_PUBLIC_KEY)
    except (EnvelopeError, ControlPayloadError) as rejection:
        assert rejection.reason == vector["reason"]
    else:
        pytest.fail(f"{vector['name']} was accepted; expected {vector['reason']}")


def test_a_certificate_wrapped_around_another_devices_envelope_is_refused() -> None:
    """D6 step 4, the load-bearing one.

    A genuine Root-signed certificate is public once it is in the log.  Without
    checking the envelope signature against the certificate's own key, anyone
    holding a copy could wrap it around self-signed envelopes and manufacture
    forks in the victim's chain.
    """
    genuine = _DOCUMENT["control_vectors"][0]
    payload = env.parse_body(env.split_envelope(bytes.fromhex(genuine["envelope_hex"]))[1])
    header = _header_from_json(genuine["header"])

    forger = SigningKey(bytes.fromhex(_KEYS_BY_LABEL["device_b"]["seed_hex"]))
    forged = env.build_envelope(header, env.frame_body(payload), forger)

    with pytest.raises(env.BadSignatureEnvelopeError):
        _receive_control(forged, _ROOT_PUBLIC_KEY)


# --- Escrow and challenge preimages -----------------------------------------


def test_escrow_constants_match_the_frozen_file() -> None:
    frozen = _PROTOCOL["escrow"]
    assert frozen["blob_magic"] == esc.ESCROW_BLOB_MAGIC.decode("ascii")
    assert frozen["salt_bytes"] == esc.ESCROW_SALT_BYTES
    assert frozen["nonce_bytes"] == esc.ESCROW_NONCE_BYTES
    assert frozen["secret_bytes"] == esc.ESCROW_SECRET_BYTES
    assert frozen["blob_header_bytes"] == esc.ESCROW_BLOB_HEADER_BYTES
    assert frozen["blob_bytes"] == esc.ESCROW_BLOB_BYTES
    assert frozen["first_version"] == esc.FIRST_ESCROW_VERSION
    assert frozen["argon2id_floor"] == {
        "memory_kib": esc.ARGON2ID_FLOOR_MEMORY_KIB,
        "time_cost": esc.ARGON2ID_FLOOR_TIME_COST,
        "parallelism": esc.ARGON2ID_FLOOR_PARALLELISM,
    }


@pytest.mark.parametrize("vector", _DOCUMENT["escrow_vectors"], ids=lambda v: str(v["name"]))
def test_escrow_signature_vector_is_byte_identical(vector: dict[str, Any]) -> None:
    workspace_id = uuid.UUID(vector["workspace_id"])
    blob = bytes.fromhex(vector["blob_hex"])
    signing_input = esc.escrow_signing_input(workspace_id, vector["version"], blob)
    assert signing_input.hex() == vector["signing_input_hex"]
    # The slot is inside the signed bytes: workspace first, then the version.
    assert signing_input.startswith(esc.SIGNING_DOMAIN_ESCROW_V1 + workspace_id.bytes)

    root = SigningKey(bytes.fromhex(_IDENTITIES["root"]["seed_hex"]))
    assert (
        esc.sign_escrow(workspace_id, vector["version"], blob, root).hex() == vector["root_sig_hex"]
    )
    esc.verify_escrow_signature(
        workspace_id,
        vector["version"],
        blob,
        bytes.fromhex(vector["root_sig_hex"]),
        _ROOT_PUBLIC_KEY,
    )


def test_an_escrow_signature_does_not_transfer_between_slots_or_versions() -> None:
    first, second = _DOCUMENT["escrow_vectors"]
    assert first["root_sig_hex"] != second["root_sig_hex"]
    blob = bytes.fromhex(first["blob_hex"])
    signature = bytes.fromhex(first["root_sig_hex"])

    with pytest.raises(esc.EscrowSignatureError):
        esc.verify_escrow_signature(
            uuid.UUID(first["workspace_id"]), second["version"], blob, signature, _ROOT_PUBLIC_KEY
        )
    with pytest.raises(esc.EscrowSignatureError):
        esc.verify_escrow_signature(
            uuid.UUID(_IDENTITIES["other_workspace_id"]),
            first["version"],
            blob,
            signature,
            _ROOT_PUBLIC_KEY,
        )


@pytest.mark.parametrize(
    "vector", _DOCUMENT["member_challenge_vectors"], ids=lambda v: str(v["name"])
)
def test_member_challenge_vector_is_byte_identical(vector: dict[str, Any]) -> None:
    member_id = uuid.UUID(vector["member_id"])
    nonce = bytes.fromhex(vector["nonce_hex"])
    signing_input = member_auth.member_challenge_signing_input(member_id, nonce)
    assert signing_input.hex() == vector["signing_input_hex"]

    key_entry = _KEYS_BY_LABEL[vector["key"]]
    signing_key = SigningKey(bytes.fromhex(key_entry["seed_hex"]))
    assert signing_key.sign(signing_input).signature.hex() == vector["signature_hex"]
    member_auth.verify_member_challenge(
        member_id,
        nonce,
        bytes.fromhex(vector["signature_hex"]),
        bytes.fromhex(key_entry["sign_pk_hex"]),
    )

    # The member id is inside the preimage, so the same nonce under another
    # member's slot is a different signature.
    with pytest.raises(member_auth.MemberChallengeError):
        member_auth.verify_member_challenge(
            uuid.UUID(_KEYS_BY_LABEL["device_b"]["member_id"]),
            nonce,
            bytes.fromhex(vector["signature_hex"]),
            bytes.fromhex(key_entry["sign_pk_hex"]),
        )
