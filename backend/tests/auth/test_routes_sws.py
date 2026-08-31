"""Integration tests for the SWS auth routes (POST /auth/sws/challenge and POST /auth/sws).

The `client` and `signing_key` fixtures live in tests/auth/conftest.py.
"""

import base64

import pytest
from httpx import AsyncClient
from nacl.signing import SigningKey

from app.auth.providers.sws_strategy import SIWS_TEMPLATE


def _b58encode(data: bytes) -> str:
    import base58 as _base58

    return _base58.b58encode(data).decode()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_sws_challenge_returns_nonce(client: AsyncClient, signing_key: SigningKey) -> None:
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    response = await client.post("/auth/sws/challenge", json={"public_key": public_key_b58})
    assert response.status_code == 200
    data = response.json()
    assert data["nonce"]
    assert data["issued_at"]
    assert data["domain"] == "jeeves.app"


@pytest.mark.asyncio
async def test_sws_login_happy_path(client: AsyncClient, signing_key: SigningKey) -> None:
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))

    # Step 1: get challenge.
    challenge = await client.post("/auth/sws/challenge", json={"public_key": public_key_b58})
    assert challenge.status_code == 200
    nonce = challenge.json()["nonce"]
    issued_at = challenge.json()["issued_at"]

    # Step 2: sign the SIWS message.
    message = SIWS_TEMPLATE.format(
        domain="jeeves.app",
        public_key=public_key_b58,
        nonce=nonce,
        issued_at=issued_at,
    ).encode()
    signed = signing_key.sign(message)
    signature_b64 = base64.b64encode(signed.signature).decode()

    # Step 3: login.
    response = await client.post(
        "/auth/sws",
        json={
            "public_key": public_key_b58,
            "signature": signature_b64,
            "nonce": nonce,
        },
    )
    assert response.status_code == 200
    data = response.json()
    assert data["access_token"]
    assert data["refresh_token"]
    assert data["token_type"] == "bearer"


@pytest.mark.asyncio
async def test_sws_login_bad_signature_returns_401(
    client: AsyncClient, signing_key: SigningKey
) -> None:
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))

    challenge = await client.post("/auth/sws/challenge", json={"public_key": public_key_b58})
    nonce = challenge.json()["nonce"]
    bad_sig = base64.b64encode(b"\x00" * 64).decode()

    response = await client.post(
        "/auth/sws",
        json={
            "public_key": public_key_b58,
            "signature": bad_sig,
            "nonce": nonce,
        },
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_sws_login_missing_nonce_returns_401(
    client: AsyncClient, signing_key: SigningKey
) -> None:
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    bad_sig = base64.b64encode(b"\x00" * 64).decode()

    response = await client.post(
        "/auth/sws",
        json={
            "public_key": public_key_b58,
            "signature": bad_sig,
            "nonce": "totally-made-up-nonce",
        },
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_sws_login_malformed_public_key_returns_401(client: AsyncClient) -> None:
    """A public key that is not base58 at all is a bad credential, not a server fault."""
    malformed_public_key = "not-a-valid-base58-key!!"

    challenge = await client.post("/auth/sws/challenge", json={"public_key": malformed_public_key})
    nonce = challenge.json()["nonce"]

    response = await client.post(
        "/auth/sws",
        json={
            "public_key": malformed_public_key,
            "signature": base64.b64encode(b"\x00" * 64).decode(),
            "nonce": nonce,
        },
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_sws_login_wrong_length_public_key_returns_401(client: AsyncClient) -> None:
    """Valid base58 that decodes to something other than 32 bytes is still a bad credential."""
    short_public_key = _b58encode(b"\x01" * 16)

    challenge = await client.post("/auth/sws/challenge", json={"public_key": short_public_key})
    nonce = challenge.json()["nonce"]

    response = await client.post(
        "/auth/sws",
        json={
            "public_key": short_public_key,
            "signature": base64.b64encode(b"\x00" * 64).decode(),
            "nonce": nonce,
        },
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_sws_login_malformed_signature_returns_401(
    client: AsyncClient, signing_key: SigningKey
) -> None:
    """A signature that is not decodable base64 is a bad credential."""
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))

    challenge = await client.post("/auth/sws/challenge", json={"public_key": public_key_b58})
    nonce = challenge.json()["nonce"]

    response = await client.post(
        "/auth/sws",
        json={
            "public_key": public_key_b58,
            "signature": "!!!not-base64!!!",
            "nonce": nonce,
        },
    )
    assert response.status_code == 401
