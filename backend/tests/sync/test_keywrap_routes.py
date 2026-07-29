"""The key plane: uploading wraps, fetching one's own, and the epoch escrow.

The server's whole role here is storage and arithmetic.  It holds wraps it cannot
open and checks a hash it was *told* to check — and that telling is the interesting
part: a ``rotate`` op is signed by an owner and names ``keywrap_digest`` before any
wrap exists, so refusing a set that does not hash to it is the server holding itself
to somebody else's word rather than inventing a policy.

These tests therefore concentrate on the two things route tests can prove and
vectors cannot: **who** may do each of these things, and **what the digest refuses**.
The byte-level construction of a wrap is pinned by
``spec/sync/envelope_v1_vectors.json``'s ``keywrap_vectors`` on both sides.
"""

from __future__ import annotations

import base64
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.sync.control_payload import CONTROL_TYPE_ROTATE, ControlPayload, RotateStatement
from app.sync.envelope import OP_CLASS_CONTENT, OP_CLASS_CONTROL, WORKSPACE_KEY_BYTES
from app.sync.key_wraps import (
    EPOCH_KEY_ESCROW_WRAP_BYTES,
    KEYWRAP_BYTES,
    keywrap_digest,
    unwrap_epoch_key_for_member,
    unwrap_epoch_key_from_escrow,
    wrap_epoch_key_for_escrow,
    wrap_epoch_key_for_member,
)
from app.sync.models import KeyWrap, WorkspaceEpoch
from app.sync.op_payload import Hlc
from tests.sync.builders import (
    Session,
    SpecDevice,
    encode_all,
    member_token,
    open_session,
)
from tests.sync.helpers import detail_of

#: A Workspace content key, and the master wrap key the escrow carries.  Fixed
#: rather than random so a failure message names the same bytes twice.
EPOCH_KEY = bytes(range(1, WORKSPACE_KEY_BYTES + 1))
MASTER_WRAP_KEY = bytes(range(100, 100 + WORKSPACE_KEY_BYTES))
EPHEMERAL_SEED = bytes(range(200, 200 + 32))
WRAP_NONCE = bytes(range(50, 50 + 24))
ESCROW_NONCE = bytes(range(80, 80 + 24))


@pytest_asyncio.fixture
async def session(client: AsyncClient) -> Session:
    return await open_session(client, "keywrap-owner@example.com")


def _wrap_for(session: Session, device: SpecDevice, *, epoch: int = 1) -> bytes:
    return wrap_epoch_key_for_member(
        workspace_key=EPOCH_KEY,
        kex_pk=device.kex_pk,
        workspace_id=session.workspace_id,
        epoch=epoch,
        member_id=device.member_id,
        kex_key_id=device.kex_key_id_for_wraps,
        ephemeral_secret_key=EPHEMERAL_SEED,
        nonce=WRAP_NONCE,
    )


def _escrow_wrap_for(session: Session, *, epoch: int = 1) -> bytes:
    return wrap_epoch_key_for_escrow(
        workspace_key=EPOCH_KEY,
        master_wrap_key=MASTER_WRAP_KEY,
        workspace_id=session.workspace_id,
        epoch=epoch,
        nonce=ESCROW_NONCE,
    )


def _put_body(
    session: Session,
    devices: list[SpecDevice],
    *,
    epoch: int = 1,
    include_digest: bool = False,
) -> dict[str, object]:
    escrow_wrap = _escrow_wrap_for(session, epoch=epoch)
    entries = [(device, _wrap_for(session, device, epoch=epoch)) for device in devices]
    body: dict[str, object] = {
        "epoch": epoch,
        "escrow_wrap_b64": base64.b64encode(escrow_wrap).decode("ascii"),
        "wraps": [
            {
                "member_id": str(device.member_id),
                "kex_key_id": base64.b64encode(device.kex_key_id_for_wraps).decode("ascii"),
                "wrap_b64": base64.b64encode(wrap).decode("ascii"),
            }
            for device, wrap in entries
        ],
    }
    if include_digest:
        body["keywrap_digest_b64"] = base64.b64encode(
            keywrap_digest(
                epoch=epoch,
                member_wraps=[
                    (device.member_id, device.kex_key_id_for_wraps, wrap)
                    for device, wrap in entries
                ],
                escrow_wrap=escrow_wrap,
            )
        ).decode("ascii")
    return body


def _digest_for(session: Session, devices: list[SpecDevice], *, epoch: int = 1) -> bytes:
    escrow_wrap = _escrow_wrap_for(session, epoch=epoch)
    return keywrap_digest(
        epoch=epoch,
        member_wraps=[
            (device.member_id, device.kex_key_id_for_wraps, _wrap_for(session, device, epoch=epoch))
            for device in devices
        ],
        escrow_wrap=escrow_wrap,
    )


async def _rotate(
    client: AsyncClient,
    session: Session,
    devices: list[SpecDevice],
    *,
    from_epoch: int = 0,
) -> None:
    """Author the ``rotate`` that commits to ``devices``' wrap set, and post it."""
    envelope = session.advance_control_head(
        session.device.rotate_envelope(
            session.workspace_id,
            prev_control_hash=session.control_head,
            keywrap_digest=_digest_for(session, devices, epoch=from_epoch + 1),
            from_epoch=from_epoch,
        )
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text


# ── The rotate op itself ──────────────────────────────────────────────────────


async def test_a_rotate_materialises_an_epoch_row_with_no_wraps_yet(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The epoch exists, committed to a digest, and nothing can read it yet.

    That ordering is the whole mechanism rather than a wart: the digest has to be in
    the log *before* the wraps arrive, or there is nothing to check them against.
    The window in between is the named orphaned-grant state a client re-fetches
    through.
    """
    await _rotate(client, session, [session.device])

    row = await db.get(WorkspaceEpoch, (session.workspace_id, 1))
    assert row is not None
    assert row.keywrap_digest == _digest_for(session, [session.device])
    assert row.escrow_wrap == b""
    assert row.rotate_seq is not None
    assert (await db.execute(select(KeyWrap))).scalars().all() == []


async def test_a_rotate_needs_a_live_owner_grant(client: AsyncClient) -> None:
    """No certificate means no Root shortcut: the role matrix is the whole gate.

    Every other control type can land on a Root signature alone, which is how an
    ungranted device's register-plus-grant batch gets in.  A rotate cannot, and that
    is the intended consequence of it carrying no certificate.
    """
    ungranted = await open_session(client, "keywrap-ungranted@example.com", genesis=False)
    response = await client.post(
        f"/w/{ungranted.workspace_id}/ops",
        json=encode_all(
            ungranted.device.rotate_envelope(
                ungranted.workspace_id,
                # A non-zero link: the zero link is genesis-only, and this must fail
                # on authority rather than on chain shape.
                prev_control_hash=b"\x11" * 32,
                keywrap_digest=b"\x22" * 32,
            )
        ),
        headers=ungranted.headers,
    )
    assert response.status_code in (403, 409), response.text


async def test_a_rotate_from_the_wrong_epoch_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """Two owners racing a rotation cannot both land.

    ``from_epoch`` must be where the Workspace actually is, so the loser learns which
    epoch it should have rotated from and re-pulls, instead of the log ending up
    claiming two different keys for one epoch.
    """
    await _rotate(client, session, [session.device])
    envelope = session.device.rotate_envelope(
        session.workspace_id,
        prev_control_hash=session.control_head,
        keywrap_digest=b"\x33" * 32,
        from_epoch=0,
    )
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=session.headers,
    )
    assert response.status_code == 409, response.text
    detail = detail_of(response)
    assert detail["code"] == "rotate_epoch_conflict"
    assert detail["expected_from_epoch"] == 1


async def test_a_multi_step_rotation_is_refused_at_decode(
    client: AsyncClient, session: Session
) -> None:
    """``to_epoch`` must be ``from_epoch + 1``.

    A jump would leave an epoch no KeyWrap set is ever minted for, and the client's
    epoch floor would then refuse content at an epoch the Workspace never keyed.
    """
    statement = RotateStatement(
        workspace_id=session.workspace_id,
        from_epoch=0,
        to_epoch=1,
        keywrap_digest=b"\x44" * 32,
        rotated_at_hlc=Hlc.for_member(session.device.member_id, 1_800_000_000_000),
    )
    payload = ControlPayload(
        control_type=CONTROL_TYPE_ROTATE,
        prev_control_hash=session.control_head,
        rotate=statement,
    ).encode()
    # Rewritten after encoding: the dataclass will serialise a two-step rotation but
    # ``from_json_dict`` refuses to read one back, which is exactly the shape this
    # test has to put on the wire.
    tampered = payload.replace(b'"to_epoch":1', b'"to_epoch":2')
    assert tampered != payload
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(
            session.device.next_envelope(
                session.workspace_id, op_class=OP_CLASS_CONTROL, payload=tampered
            )
        ),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "malformed_control_payload"


# ── PUT /w/{w}/keywraps ───────────────────────────────────────────────────────


async def test_wraps_land_when_they_hash_to_the_rotates_digest(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The happy path, and the round-trip that proves the bytes are usable.

    Both wrap flavours are unwrapped here rather than merely stored and compared: a
    route that accepted an unopenable wrap would pass a byte-equality test and lock
    the member out in the field.
    """
    await _rotate(client, session, [session.device])
    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device]),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text
    assert [entry["epoch"] for entry in response.json()["wraps"]] == [1]

    stored = await db.get(KeyWrap, (session.workspace_id, session.device.member_id, 1))
    assert stored is not None
    assert (
        unwrap_epoch_key_for_member(
            wrap=stored.wrap,
            kex_secret_key=bytes(session.device.kex_key),
            workspace_id=session.workspace_id,
            epoch=1,
            member_id=session.device.member_id,
            kex_key_id=session.device.kex_key_id_for_wraps,
        )
        == EPOCH_KEY
    )

    epoch_row = await db.get(WorkspaceEpoch, (session.workspace_id, 1))
    assert epoch_row is not None
    assert (
        unwrap_epoch_key_from_escrow(
            escrow_wrap=epoch_row.escrow_wrap,
            master_wrap_key=MASTER_WRAP_KEY,
            workspace_id=session.workspace_id,
            epoch=1,
        )
        == EPOCH_KEY
    )


async def test_an_omitted_wrap_is_refused_by_the_digest(
    client: AsyncClient, session: Session
) -> None:
    """The defence that matters: the server cannot lock an honest member out.

    A curating operator's cheapest attack is to drop one member's wrap and let them
    look orphaned.  The rotate committed to a two-member set, so a one-member upload
    does not hash to it.
    """
    second = SpecDevice()
    registered = await client.post(
        "/members", json=second.registration_body(), headers=session.user_headers
    )
    assert registered.status_code == 201, registered.text
    await _rotate(client, session, [session.device, second])

    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device]),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "keywrap_digest_mismatch"


async def test_an_added_wrap_is_refused_by_the_digest(
    client: AsyncClient, session: Session
) -> None:
    """The mirror attack: a wrap for a member the owner never wrapped to."""
    second = SpecDevice()
    registered = await client.post(
        "/members", json=second.registration_body(), headers=session.user_headers
    )
    assert registered.status_code == 201, registered.text
    await _rotate(client, session, [session.device])

    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device, second]),
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "keywrap_digest_mismatch"


async def test_a_substituted_escrow_wrap_is_refused_by_the_digest(
    client: AsyncClient, session: Session
) -> None:
    """The escrow wrap is inside the digest, so it cannot be swapped either.

    Without it in the commitment, an operator could keep every member wrap honest and
    replace only the blob a fresh device recovers from — the one path with no second
    device to notice.
    """
    await _rotate(client, session, [session.device])
    body = _put_body(session, [session.device])
    body["escrow_wrap_b64"] = base64.b64encode(
        wrap_epoch_key_for_escrow(
            workspace_key=EPOCH_KEY,
            master_wrap_key=MASTER_WRAP_KEY,
            workspace_id=session.workspace_id,
            epoch=1,
            nonce=bytes(24),
        )
    ).decode("ascii")

    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=body,
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "keywrap_digest_mismatch"


async def test_wraps_without_a_materialised_rotate_are_refused(
    client: AsyncClient, session: Session
) -> None:
    """A digest the log has not committed to is just a number the uploader chose."""
    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device], include_digest=True),
        headers=session.headers,
    )
    assert response.status_code == 409, response.text
    assert detail_of(response)["code"] == "rotate_not_materialised"


async def test_epoch_zero_carries_its_own_digest(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """The one epoch with no rotate behind it — nothing rotated *to* it.

    This is a Workspace keyed at genesis.  A Workspace that predates encryption never
    mints an epoch 0 row at all: turn-on gives it ``K_{w,1}``, which is what leaves
    its plaintext history readable for ever.
    """
    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device], epoch=0, include_digest=True),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text
    row = await db.get(WorkspaceEpoch, (session.workspace_id, 0))
    assert row is not None
    assert row.rotate_seq is None
    assert row.keywrap_digest == _digest_for(session, [session.device], epoch=0)


async def test_an_epoch_zero_digest_that_does_not_describe_its_own_set_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """Self-inconsistency is refused rather than silently corrected.

    A client that miscomputes the digest here would miscompute it in the ``rotate``
    op it signs next, where nothing can correct it.
    """
    body = _put_body(session, [session.device], epoch=0, include_digest=True)
    body["keywrap_digest_b64"] = base64.b64encode(bytes(32)).decode("ascii")
    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=body,
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "keywrap_digest_mismatch"


async def test_a_byte_identical_replay_is_idempotent(
    client: AsyncClient, session: Session, db: AsyncSession
) -> None:
    """Both ceremonies retry, so a re-PUT of the same bytes is an acknowledgement."""
    await _rotate(client, session, [session.device])
    body = _put_body(session, [session.device])
    first = await client.put(
        f"/w/{session.workspace_id}/keywraps", json=body, headers=session.headers
    )
    assert first.status_code == 200, first.text
    second = await client.put(
        f"/w/{session.workspace_id}/keywraps", json=body, headers=session.headers
    )
    assert second.status_code == 200, second.text
    assert second.json() == first.json()
    assert len((await db.execute(select(KeyWrap))).scalars().all()) == 1


async def test_wraps_require_a_live_owner_grant(client: AsyncClient, session: Session) -> None:
    """Minting wraps is the delivery half of a Grant, so it is an owner act.

    The same bar a ``rotate`` is held to — the two halves of one ceremony cannot have
    different authority, or the weaker one becomes the way in.
    """
    await _rotate(client, session, [session.device])
    second = SpecDevice()
    registered = await client.post(
        "/members", json=second.registration_body(), headers=session.user_headers
    )
    assert registered.status_code == 201, registered.text
    stranger_headers = {"Authorization": f"Bearer {await member_token(client, second)}"}

    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device]),
        headers=stranger_headers,
    )
    assert response.status_code == 403, response.text
    assert detail_of(response)["code"] == "keywrap_requires_owner"


async def test_a_wrap_naming_an_unregistered_kex_key_is_refused(
    client: AsyncClient, session: Session
) -> None:
    """``kex_key_id`` must be the one the *server* derived from the registered key.

    A wrap sealed to some other key would be undeliverable, and the member would look
    orphaned for a reason nothing in the log explained.
    """
    await _rotate(client, session, [session.device])
    body = _put_body(session, [session.device])
    wraps = body["wraps"]
    assert isinstance(wraps, list)
    wraps[0]["kex_key_id"] = base64.b64encode(bytes(8)).decode("ascii")
    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=body,
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == "kex_key_id_not_registered"


@pytest.mark.parametrize(
    ("field_name", "value", "code"),
    [
        ("escrow_wrap_b64", base64.b64encode(bytes(3)).decode("ascii"), "malformed_escrow_wrap"),
        ("escrow_wrap_b64", "not base64!", "malformed_escrow_wrap"),
    ],
)
async def test_a_malformed_escrow_wrap_is_refused_before_any_crypto(
    client: AsyncClient, session: Session, field_name: str, value: str, code: str
) -> None:
    await _rotate(client, session, [session.device])
    body = _put_body(session, [session.device])
    body[field_name] = value
    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=body,
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    assert detail_of(response)["code"] == code


async def test_a_wrap_of_the_wrong_width_is_refused_before_any_crypto(
    client: AsyncClient, session: Session
) -> None:
    await _rotate(client, session, [session.device])
    body = _put_body(session, [session.device])
    wraps = body["wraps"]
    assert isinstance(wraps, list)
    wraps[0]["wrap_b64"] = base64.b64encode(bytes(KEYWRAP_BYTES - 1)).decode("ascii")
    response = await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=body,
        headers=session.headers,
    )
    assert response.status_code == 422, response.text
    detail = detail_of(response)
    assert detail["code"] == "malformed_keywrap"
    assert detail["expected_bytes"] == KEYWRAP_BYTES


# ── GET /w/{w}/keywraps/me and /epoch-keys ────────────────────────────────────


async def test_a_member_fetches_its_own_wraps_across_every_epoch(
    client: AsyncClient, session: Session
) -> None:
    """All epochs, not just the current one.

    Soft-delete retention means content authored at any past epoch may still have to
    be read, so historical wraps are kept and served for ever.
    """
    await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device], epoch=0, include_digest=True),
        headers=session.headers,
    )
    await _rotate(client, session, [session.device])
    await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device]),
        headers=session.headers,
    )

    response = await client.get(f"/w/{session.workspace_id}/keywraps/me", headers=session.headers)
    assert response.status_code == 200, response.text
    wraps = response.json()["wraps"]
    assert [entry["epoch"] for entry in wraps] == [0, 1]
    assert {entry["member_id"] for entry in wraps} == {str(session.device.member_id)}


async def test_the_route_has_nowhere_to_ask_for_another_members_wraps(
    client: AsyncClient, session: Session
) -> None:
    """Scoped to the caller, and not parameterised — there is no id to get wrong.

    They would be unopenable anyway, which is what makes the scoping tidiness rather
    than the defence, but a route with no parameter cannot be talked into leaking.
    """
    second = SpecDevice()
    registered = await client.post(
        "/members", json=second.registration_body(), headers=session.user_headers
    )
    assert registered.status_code == 201, registered.text
    await _rotate(client, session, [session.device])
    await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device]),
        headers=session.headers,
    )

    stranger_headers = {"Authorization": f"Bearer {await member_token(client, second)}"}
    response = await client.get(f"/w/{session.workspace_id}/keywraps/me", headers=stranger_headers)
    assert response.status_code == 200, response.text
    assert response.json()["wraps"] == []


async def test_epoch_keys_serves_the_escrow_wraps_to_a_granted_member(
    client: AsyncClient, session: Session
) -> None:
    """The route that makes a fresh device's bootstrap work with no second device.

    Passphrase → ``master_wrap_key`` → every historical epoch key → the whole history.
    Served on a low bar because the bytes disclose nothing on their own: anyone who
    can open these can already open Root.
    """
    await _rotate(client, session, [session.device])
    await client.put(
        f"/w/{session.workspace_id}/keywraps",
        json=_put_body(session, [session.device]),
        headers=session.headers,
    )

    response = await client.get(f"/w/{session.workspace_id}/epoch-keys", headers=session.headers)
    assert response.status_code == 200, response.text
    epochs = response.json()["epochs"]
    assert [entry["epoch"] for entry in epochs] == [1]
    assert (
        unwrap_epoch_key_from_escrow(
            escrow_wrap=base64.b64decode(epochs[0]["escrow_wrap_b64"]),
            master_wrap_key=MASTER_WRAP_KEY,
            workspace_id=session.workspace_id,
            epoch=1,
        )
        == EPOCH_KEY
    )


async def test_epoch_keys_omits_an_epoch_whose_wraps_have_not_arrived(
    client: AsyncClient, session: Session
) -> None:
    """The window between a rotate landing and its wraps PUT.

    Serving an empty blob would make it look like a wrap that fails to open — an
    alarm — instead of one that has not arrived, which is a healable delivery gap.
    """
    await _rotate(client, session, [session.device])
    response = await client.get(f"/w/{session.workspace_id}/epoch-keys", headers=session.headers)
    assert response.status_code == 200, response.text
    assert response.json()["epochs"] == []


async def test_epoch_keys_refuses_an_ungranted_member(client: AsyncClient) -> None:
    ungranted = await open_session(client, "keywrap-nogrant@example.com", genesis=False)
    response = await client.get(
        f"/w/{ungranted.workspace_id}/epoch-keys", headers=ungranted.headers
    )
    assert response.status_code == 403, response.text
    assert detail_of(response)["code"] == "no_live_grant"


# ── key_epoch_stale on content POSTs ──────────────────────────────────────────


async def test_content_at_the_previous_epoch_still_lands(
    client: AsyncClient, session: Session
) -> None:
    """One epoch of slack, and it is load-bearing.

    A device offline across a rotation holds outbox envelopes signed at the previous
    epoch, and those cannot be re-signed without forging its own chain. Refusing them
    would wedge an honest queue; two epochs of slack would make the floor meaningless.
    """
    await _rotate(client, session, [session.device])
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(
            session.device.next_envelope(
                session.workspace_id, op_class=OP_CLASS_CONTENT, key_epoch=0
            )
        ),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text


async def test_content_two_epochs_behind_is_refused(client: AsyncClient, session: Session) -> None:
    await _rotate(client, session, [session.device])
    await _rotate(client, session, [session.device], from_epoch=1)
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(
            session.device.next_envelope(
                session.workspace_id, op_class=OP_CLASS_CONTENT, key_epoch=0
            )
        ),
        headers=session.headers,
    )
    assert response.status_code == 409, response.text
    detail = detail_of(response)
    assert detail["code"] == "key_epoch_stale"
    assert (detail["key_epoch"], detail["current_epoch"]) == (0, 2)


async def test_an_unkeyed_workspace_refuses_no_epoch(client: AsyncClient, session: Session) -> None:
    """The property that keeps ``plaintext_v1`` clients working after 0034.

    With no epoch rows there is nothing to be stale against, and content at epoch 0
    is exactly what a pre-turn-on Workspace writes.
    """
    response = await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(
            session.device.next_envelope(
                session.workspace_id, op_class=OP_CLASS_CONTENT, key_epoch=0
            )
        ),
        headers=session.headers,
    )
    assert response.status_code == 200, response.text


async def test_the_escrow_wrap_width_is_what_the_codec_says(
    client: AsyncClient, session: Session
) -> None:
    """A guard against the route and the codec disagreeing about a width."""
    assert len(_escrow_wrap_for(session)) == EPOCH_KEY_ESCROW_WRAP_BYTES
    assert len(_wrap_for(session, session.device)) == KEYWRAP_BYTES
    assert isinstance(session.workspace_id, uuid.UUID)
