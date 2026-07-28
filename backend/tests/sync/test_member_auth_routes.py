"""Member-scoped transport auth: the proof-of-possession exchange.

Its twin on the Dart side is the ``connectAsMember`` half of
``fake_sync_server_contract_test.dart``.
"""

from __future__ import annotations

import base64
import uuid

import jwt
import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import RefreshToken
from app.config import settings
from app.sync.ids import default_workspace_id
from app.sync.member_auth import TOKEN_USE_MEMBER, member_challenge_counter_key
from app.sync.models import RecoveryEscrowFetch
from app.sync.routes import revoke_member_transport
from tests.conftest import auth_header, register
from tests.sync.builders import SpecDevice, SpecRoot, encode_all, user_id_from_token
from tests.sync.helpers import detail_of


class Enrolled:
    def __init__(self, token: str, user_id: str, device: SpecDevice) -> None:
        self.token = token
        self.user_id = user_id
        self.device = device
        self.workspace_id = default_workspace_id(user_id)


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


async def _member_tokens(client: AsyncClient, enrolled: Enrolled) -> dict[str, str]:
    """Run the ceremony through to a member-scoped access + refresh token pair."""
    nonce = await _challenge(client, enrolled.device.member_id)
    response = await client.post(
        f"/members/{enrolled.device.member_id}/token",
        json={"nonce": nonce, "signature": enrolled.device.challenge_signature(nonce)},
    )
    assert response.status_code == 200, response.text
    tokens: dict[str, str] = response.json()
    return tokens


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

    # The pull is the unambiguous proof: a **pre-genesis GET on a derivable
    # Workspace returns an empty page**, which is precisely the state the
    # enrolment ceremony reads before it decides whether to author a genesis.  A
    # token that had not reached the route would 401, not page.
    pulled = await client.get(f"/w/{enrolled.workspace_id}/ops", headers=auth_header(token))
    assert pulled.status_code == 200, pulled.text
    assert pulled.json() == {"ops": [], "has_more": False}

    # And the POST reaches the route too: it is refused on the Workspace's own
    # state — nobody has signed this Workspace into existence — rather than on the
    # credential, which is what separates a 409 here from a 401 or a 403.
    posted = await client.post(
        f"/w/{enrolled.workspace_id}/ops",
        json=encode_all(enrolled.device.next_envelope(enrolled.workspace_id)),
        headers=auth_header(token),
    )
    assert posted.status_code == 409, posted.text
    assert detail_of(posted) == {"code": "workspace_not_created", "index": 0}


async def test_a_nonce_is_single_use(client: AsyncClient) -> None:
    enrolled = await _enrol(client, "pop-replay@example.com")
    nonce = await _challenge(client, enrolled.device.member_id)
    body = {"nonce": nonce, "signature": enrolled.device.challenge_signature(nonce)}
    assert (
        await client.post(f"/members/{enrolled.device.member_id}/token", json=body)
    ).status_code == 200
    replay = await client.post(f"/members/{enrolled.device.member_id}/token", json=body)
    assert replay.status_code == 401, replay.text
    assert detail_of(replay) == {"code": "bad_member_challenge"}


async def test_a_wrong_key_cannot_answer_the_challenge(client: AsyncClient) -> None:
    enrolled = await _enrol(client, "pop-wrong-key@example.com")
    nonce = await _challenge(client, enrolled.device.member_id)
    impostor = SpecDevice(member_id=enrolled.device.member_id)
    response = await client.post(
        f"/members/{enrolled.device.member_id}/token",
        json={"nonce": nonce, "signature": impostor.challenge_signature(nonce)},
    )
    assert response.status_code == 401, response.text
    assert detail_of(response) == {"code": "bad_member_challenge"}


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
    assert detail_of(response) == {"code": "bad_member_challenge"}


async def test_an_unknown_member_has_no_challenge(client: AsyncClient) -> None:
    response = await client.post(f"/members/{uuid.uuid4()}/challenge")
    assert response.status_code == 404, response.text
    assert detail_of(response) == {"code": "unknown_member"}


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
    assert detail_of(reuse) == {"code": "invalid_refresh_token"}

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
    assert detail_of(response) == {"code": "invalid_refresh_token"}


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
    assert detail_of(refused) == {"code": "invalid_refresh_token"}


async def test_a_wrong_length_nonce_is_a_401(client: AsyncClient) -> None:
    """Well-formed base64 that decodes to the wrong width is a failed proof."""
    enrolled = await _enrol(client, "pop-malformed@example.com")
    response = await client.post(
        f"/members/{enrolled.device.member_id}/token",
        json={
            "nonce": base64.b64encode(b"short").decode("ascii"),
            "signature": base64.b64encode(bytes(64)).decode("ascii"),
        },
    )
    assert response.status_code == 401, response.text
    assert detail_of(response) == {"code": "bad_member_challenge"}


async def test_a_nonce_that_is_not_base64_is_a_422(client: AsyncClient) -> None:
    """The pairing with the case above: unreadable is a 422, wrong is a 401.

    Both carry ``bad_member_challenge`` — the status is what separates "this
    request is not decodable" from "this proof did not check out", and neither
    tells the caller anything about the member's key.
    """
    enrolled = await _enrol(client, "pop-not-base64@example.com")
    response = await client.post(
        f"/members/{enrolled.device.member_id}/token",
        json={
            "nonce": "not base64 at all!!",
            "signature": base64.b64encode(bytes(64)).decode("ascii"),
        },
    )
    assert response.status_code == 422, response.text
    assert detail_of(response) == {"code": "bad_member_challenge"}


# --- Credential separation ----------------------------------------------------


async def test_a_member_refresh_token_cannot_mint_a_user_session(
    client: AsyncClient,
) -> None:
    """The other half of the refresh pair, and the one that was open.

    ``get_current_user`` refuses a member *access* token, so a Device cannot
    reach the User surface with the token it was handed.  But a refresh token is
    not a JWT and carries no ``token_use`` — it is a row.  Unless
    ``/session/refresh`` refuses a row with a ``member_id``, a Device launders
    its member refresh token into a full user session and every check above it
    is decoration.
    """
    enrolled = await _enrol(client, "pop-launder@example.com")
    tokens = await _member_tokens(client, enrolled)

    response = await client.post(
        "/session/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert response.status_code == 401, response.text
    assert response.json()["detail"] == "Invalid or expired refresh token"


async def test_a_refused_laundering_attempt_does_not_rotate_the_member_token(
    client: AsyncClient, db: AsyncSession
) -> None:
    """Refusing early matters: the member's own credential is left untouched."""
    enrolled = await _enrol(client, "pop-launder-intact@example.com")
    tokens = await _member_tokens(client, enrolled)

    await client.post("/session/refresh", json={"refresh_token": tokens["refresh_token"]})

    stored = (
        (await db.execute(select(RefreshToken).where(RefreshToken.member_id.is_not(None))))
        .scalars()
        .all()
    )
    assert [row.revoked_at for row in stored] == [None]
    # And it still rotates at the endpoint that is actually its own.
    rotated = await client.post(
        f"/members/{enrolled.device.member_id}/token/refresh",
        json={"refresh_token": tokens["refresh_token"]},
    )
    assert rotated.status_code == 200, rotated.text


async def test_a_member_credential_can_never_reach_the_escrow_blob(
    client: AsyncClient, db: AsyncSession
) -> None:
    """Every door from a member credential to the escrow, tried and shut.

    The escrow is the passphrase-wrapped Root: reaching it is reaching the
    account.  A Device holds a member credential and nothing else once enrolment
    is over, so this walks the whole laundering graph from there — the access
    token directly, the refresh token via the user session route, and a
    *rotated* member access token after that — and ends on the audit table,
    which is the evidence no bytes left the server.
    """
    enrolled = await _enrol(client, "pop-escrow-unreachable@example.com")
    root = SpecRoot()
    written = await client.put(
        f"/w/{enrolled.workspace_id}/recovery",
        json=root.escrow_body(enrolled.workspace_id),
        headers=auth_header(enrolled.token),
    )
    assert written.status_code == 200, written.text

    tokens = await _member_tokens(client, enrolled)

    # 1. The member access token on the escrow routes: it is not a user session.
    direct = await client.get(
        f"/w/{enrolled.workspace_id}/recovery", headers=auth_header(tokens["access_token"])
    )
    assert direct.status_code == 401, direct.text
    assert (
        await client.put(
            f"/w/{enrolled.workspace_id}/recovery",
            json=root.escrow_body(enrolled.workspace_id, version=2),
            headers=auth_header(tokens["access_token"]),
        )
    ).status_code == 401

    # 2. The member refresh token traded for a user session: refused, so there is
    #    no user access token to arrive at step 1 with.
    laundered = await client.post(
        "/session/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert laundered.status_code == 401, laundered.text
    assert "access_token" not in laundered.json()

    # 3. Rotating properly first buys nothing: what comes back is a member token
    #    again, and it is refused exactly as the first one was.
    rotated = await client.post(
        f"/members/{enrolled.device.member_id}/token/refresh",
        json={"refresh_token": tokens["refresh_token"]},
    )
    assert rotated.status_code == 200, rotated.text
    assert (
        await client.get(
            f"/w/{enrolled.workspace_id}/recovery",
            headers=auth_header(rotated.json()["access_token"]),
        )
    ).status_code == 401
    assert (
        await client.post(
            "/session/refresh", json={"refresh_token": rotated.json()["refresh_token"]}
        )
    ).status_code == 401

    # The audit table is empty: not one of those attempts served the blob.
    assert (await db.execute(select(RecoveryEscrowFetch))).scalars().all() == []


async def test_a_member_token_is_not_a_user_session(client: AsyncClient) -> None:
    """The User surface as a whole, not just the escrow."""
    enrolled = await _enrol(client, "pop-not-a-session@example.com")
    tokens = await _member_tokens(client, enrolled)
    headers = auth_header(tokens["access_token"])

    assert (await client.get("/user", headers=headers)).status_code == 401
    assert (
        await client.post("/members", json=SpecDevice().registration_body(), headers=headers)
    ).status_code == 401


async def test_a_user_credential_cannot_post_ops(client: AsyncClient) -> None:
    """The mirror image: the ops routes take a member token and only that."""
    enrolled = await _enrol(client, "pop-user-cannot-post@example.com")
    headers = auth_header(enrolled.token)

    posted = await client.post(
        f"/w/{enrolled.workspace_id}/ops",
        json=encode_all(enrolled.device.next_envelope(enrolled.workspace_id, advance=False)),
        headers=headers,
    )
    assert posted.status_code == 401, posted.text
    assert (await client.get(f"/w/{enrolled.workspace_id}/ops", headers=headers)).status_code == 401
    assert (
        await client.get(f"/w/{enrolled.workspace_id}/members", headers=headers)
    ).status_code == 401


# --- Rate limiting ------------------------------------------------------------


async def test_the_challenge_is_rate_limited(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An unauthenticated nonce mill becomes a 429 rather than unbounded Redis.

    The cap is lowered through Settings rather than issuing the production
    number of requests: the limiter's logic is what is under test, not its
    default.
    """
    monkeypatch.setattr(settings, "member_challenge_daily_limit", 3)
    enrolled = await _enrol(client, "pop-challenge-limit@example.com")

    for _ in range(3):
        allowed = await client.post(f"/members/{enrolled.device.member_id}/challenge")
        assert allowed.status_code == 200, allowed.text

    refused = await client.post(f"/members/{enrolled.device.member_id}/challenge")
    assert refused.status_code == 429, refused.text
    detail = detail_of(refused)
    assert detail["code"] == "member_challenge_rate_limited"
    assert isinstance(detail["retry_after_seconds"], int)
    assert detail["retry_after_seconds"] > 0


async def test_the_challenge_limit_is_per_member(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """One exhausted Device must not lock its siblings out of enrolling."""
    monkeypatch.setattr(settings, "member_challenge_daily_limit", 2)
    enrolled = await _enrol(client, "pop-challenge-per-member@example.com")
    sibling = SpecDevice()
    assert (
        await client.post(
            "/members", json=sibling.registration_body(), headers=auth_header(enrolled.token)
        )
    ).status_code == 201

    for _ in range(3):
        await client.post(f"/members/{enrolled.device.member_id}/challenge")
    assert (await client.post(f"/members/{enrolled.device.member_id}/challenge")).status_code == 429
    assert (await client.post(f"/members/{sibling.member_id}/challenge")).status_code == 200


async def test_an_unknown_member_does_not_get_a_counter(
    client: AsyncClient, redis: Redis, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The 404 comes first, so enumeration cannot fill Redis with dead counters."""
    monkeypatch.setattr(settings, "member_challenge_daily_limit", 1)
    stranger = uuid.uuid4()
    for _ in range(4):
        assert (await client.post(f"/members/{stranger}/challenge")).status_code == 404
    assert await redis.get(member_challenge_counter_key(stranger)) is None
