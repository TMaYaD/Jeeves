"""Tests for the /powersync/credentials endpoint."""

import jwt
import pytest
from httpx import AsyncClient

from app.config import settings
from tests.conftest import auth_header, register


@pytest.mark.asyncio
async def test_credentials_returns_token_and_url(client: AsyncClient) -> None:
    token = await register(client, "ps-user@example.com")
    response = await client.get("/powersync/credentials", headers=auth_header(token))
    assert response.status_code == 200
    data = response.json()
    assert "token" in data
    assert "powersync_url" in data
    assert data["powersync_url"] == settings.powersync_url


@pytest.mark.asyncio
async def test_credentials_token_has_correct_claims(client: AsyncClient) -> None:
    token = await register(client, "ps-claims@example.com")

    # Decode the API token to get the user ID.
    api_payload = jwt.decode(token, settings.secret_key, algorithms=[settings.algorithm])
    user_id = api_payload["sub"]

    response = await client.get("/powersync/credentials", headers=auth_header(token))
    assert response.status_code == 200
    ps_token = response.json()["token"]

    # PowerSync token has aud claim; pass it for decode.
    ps_payload = jwt.decode(
        ps_token,
        settings.secret_key,
        algorithms=[settings.algorithm],
        audience="jeeves",
    )
    assert ps_payload["sub"] == user_id
    assert ps_payload["aud"] == "jeeves"


@pytest.mark.asyncio
async def test_credentials_token_is_short_lived(client: AsyncClient) -> None:
    from datetime import UTC, datetime

    token = await register(client, "ps-expiry@example.com")
    response = await client.get("/powersync/credentials", headers=auth_header(token))
    ps_token = response.json()["token"]

    ps_payload = jwt.decode(
        ps_token,
        settings.secret_key,
        algorithms=[settings.algorithm],
        audience="jeeves",
    )
    exp = datetime.fromtimestamp(ps_payload["exp"], tz=UTC)
    now = datetime.now(UTC)
    ttl_minutes = (exp - now).total_seconds() / 60
    # Allow a little execution skew around the 5-minute target.
    assert ttl_minutes <= 6
    assert ttl_minutes > 0


@pytest.mark.asyncio
async def test_credentials_requires_authentication(client: AsyncClient) -> None:
    response = await client.get("/powersync/credentials")
    assert response.status_code == 401
