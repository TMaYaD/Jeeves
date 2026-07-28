"""Member-scoped transport auth: the proof-of-possession exchange.

Its twin on the Dart side is the ``connectAsMember`` half of
``fake_sync_server_contract_test.dart``.
"""

from __future__ import annotations

import base64
import uuid

import jwt
from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import RefreshToken
from app.config import settings
from app.sync.ids import implicit_workspace_id
from app.sync.member_auth import TOKEN_USE_MEMBER
from app.sync.routes import revoke_member_transport
from tests.conftest import auth_header, register
from tests.sync.builders import SpecDevice, encode_all, user_id_from_token


class Enrolled:
    def __init__(self, token: str, user_id: str, device: SpecDevice) -> None:
        self.token = token
        self.user_id = user_id
        self.device = device
        self.workspace_id = implicit_workspace_id(user_id)


async def _enrol(client: AsyncClient, email: str) -> Enrolled:
    token = await register(client, email)
    device = SpecDevice()
    response = await client.post(
        "/members", json=device.registration_body(), headers=auth_header(token)
    )
    assert response.status_code == 201, response.text
    return Enrolled(token, user_id_from_token(token), device)


async def _challenge(client: AsyncClient, member_id: uuid.UUID) -> str:
    response = await client.post(f"/members/{member_id}/challenge")
    assert response.status_code == 200, response.text
    nonce: str = response.json()["nonce"]
    return nonce


async def test_a_signed_challenge_yields_a_member_scoped_token(client: AsyncClient) -> None:
    enrolled = await _enrol(client, "pop-happy@example.com")
    nonce = await _challenge(client, enrolled.device.member_id)
    response = await client.post(
        f"/members/{enrolled.device.member_id}/token",
        json={"nonce": nonce, "signature": enrolled.device.challenge_signature(nonce)},
    )
    assert response.status_code == 200, response.text

    claims = jwt.decode(
        response.json()["access_token"], settings.secret_key, algorithms=[settings.algorithm]
    )
    assert claims["sub"] == str(enrolled.device.member_id)
    assert claims["token_use"] == TOKEN_USE_MEMBER
    assert claims["member_id"] == str(enrolled.device.member_id)
    assert claims["user_id"] == enrolled.user_id


async def test_the_member_token_reaches_the_sync_routes(client: AsyncClient) -> None:
    enrolled = await _enrol(client, "pop-reaches@example.com")
    nonce = await _challenge(client, enrolled.device.member_id)
    token = (
        await client.post(
            f"/members/{enrolled.device.member_id}/token",
            json={"nonce": nonce, "signature": enrolled.device.challenge_signature(nonce)},
        )
    ).json()["access_token"]

    posted = await client.post(
        f"/w/{enrolled.workspace_id}/ops",
        json=encode_all(enrolled.device.next_envelope(enrolled.workspace_id)),
        headers=auth_header(token),
    )
    assert posted.status_code == 200, posted.text
    pulled = await client.get(f"/w/{enrolled.workspace_id}/ops", headers=auth_header(token))
    assert pulled.status_code == 200, pulled.text
    assert len(pulled.json()["ops"]) == 1


async def test_a_nonce_is_single_use(client: AsyncClient) -> None:
    enrolled = await _enrol(client, "pop-replay@example.com")
    nonce = await _challenge(client, enrolled.device.member_id)
    body = {"nonce": nonce, "signature": enrolled.device.challenge_signature(nonce)}
    assert (
        await client.post(f"/members/{enrolled.device.member_id}/token", json=body)
    ).status_code == 200
    replay = await client.post(f"/members/{enrolled.device.member_id}/token", json=body)
    assert replay.status_code == 401, replay.text


async def test_a_wrong_key_cannot_answer_the_challenge(client: AsyncClient) -> None:
    enrolled = await _enrol(client, "pop-wrong-key@example.com")
    nonce = await _challenge(client, enrolled.device.member_id)
    impostor = SpecDevice(member_id=enrolled.device.member_id)
    response = await client.post(
        f"/members/{enrolled.device.member_id}/token",
        json={"nonce": nonce, "signature": impostor.challenge_signature(nonce)},
    )
    assert response.status_code == 401, response.text


async def test_a_signature_cannot_be_replayed_into_another_members_slot(
    client: AsyncClient,
) -> None:
    """The member id is inside the signed bytes, so a signature does not travel."""
    victim = await _enrol(client, "pop-victim@example.com")
    attacker = SpecDevice()
    registered = await client.post(
        "/members", json=attacker.registration_body(), headers=auth_header(victim.token)
    )
    assert registered.status_code == 201, registered.text

    nonce = await _challenge(client, attacker.member_id)
    # Signed for the attacker's own slot; offered for the victim's.
    signature = attacker.challenge_signature(nonce)
    response = await client.post(
        f"/members/{victim.device.member_id}/token",
        json={"nonce": nonce, "signature": signature},
    )
    assert response.status_code == 401, response.text


async def test_an_unknown_member_has_no_challenge(client: AsyncClient) -> None:
    assert (await client.post(f"/members/{uuid.uuid4()}/challenge")).status_code == 404


async def test_a_member_refresh_token_rotates(client: AsyncClient, db: AsyncSession) -> None:
    enrolled = await _enrol(client, "pop-refresh@example.com")
    nonce = await _challenge(client, enrolled.device.member_id)
    issued = (
        await client.post(
            f"/members/{enrolled.device.member_id}/token",
            json={"nonce": nonce, "signature": enrolled.device.challenge_signature(nonce)},
        )
    ).json()

    rotated = await client.post(
        f"/members/{enrolled.device.member_id}/token/refresh",
        json={"refresh_token": issued["refresh_token"]},
    )
    assert rotated.status_code == 200, rotated.text
    assert rotated.json()["refresh_token"] != issued["refresh_token"]

    reuse = await client.post(
        f"/members/{enrolled.device.member_id}/token/refresh",
        json={"refresh_token": issued["refresh_token"]},
    )
    assert reuse.status_code == 401, reuse.text

    stored = (
        (await db.execute(select(RefreshToken).where(RefreshToken.member_id.is_not(None))))
        .scalars()
        .all()
    )
    assert {row.member_id for row in stored} == {enrolled.device.member_id}


async def test_a_user_refresh_token_cannot_be_rotated_as_a_member(
    client: AsyncClient,
) -> None:
    """A user session's refresh token carries no member_id, so it is not one."""
    enrolled = await _enrol(client, "pop-user-refresh@example.com")
    session = await client.post(
        "/session", json={"email": "pop-user-refresh@example.com", "password": "secret"}
    )
    response = await client.post(
        f"/members/{enrolled.device.member_id}/token/refresh",
        json={"refresh_token": session.json()["refresh_token"]},
    )
    assert response.status_code == 401, response.text


async def test_revoking_a_member_kills_its_transport_credential(
    client: AsyncClient, db: AsyncSession
) -> None:
    """The mechanism #549's Revoke control op only has to call."""
    enrolled = await _enrol(client, "pop-revoke@example.com")
    nonce = await _challenge(client, enrolled.device.member_id)
    issued = (
        await client.post(
            f"/members/{enrolled.device.member_id}/token",
            json={"nonce": nonce, "signature": enrolled.device.challenge_signature(nonce)},
        )
    ).json()

    assert await revoke_member_transport(db, enrolled.device.member_id) == 1

    refused = await client.post(
        f"/members/{enrolled.device.member_id}/token/refresh",
        json={"refresh_token": issued["refresh_token"]},
    )
    assert refused.status_code == 401, refused.text


async def test_a_malformed_nonce_is_refused(client: AsyncClient) -> None:
    enrolled = await _enrol(client, "pop-malformed@example.com")
    response = await client.post(
        f"/members/{enrolled.device.member_id}/token",
        json={
            "nonce": base64.b64encode(b"short").decode("ascii"),
            "signature": base64.b64encode(bytes(64)).decode("ascii"),
        },
    )
    assert response.status_code == 401, response.text
