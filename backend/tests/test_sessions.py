import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, register, register_full


@pytest.mark.asyncio
async def test_login_returns_access_and_refresh_tokens(client: AsyncClient) -> None:
    await register(client, "dan@example.com", "mypassword")
    response = await client.post(
        "/session", json={"email": "dan@example.com", "password": "mypassword"}
    )
    assert response.status_code == 200
    data = response.json()
    assert data["token_type"] == "bearer"
    assert data["access_token"]
    assert data["refresh_token"]


@pytest.mark.asyncio
async def test_register_returns_access_and_refresh_tokens(client: AsyncClient) -> None:
    response = await client.post("/user", json={"email": "new@example.com", "password": "secret99"})
    assert response.status_code == 201
    data = response.json()
    assert data["access_token"]
    assert data["refresh_token"]


@pytest.mark.asyncio
async def test_login_returns_401_on_wrong_password(client: AsyncClient) -> None:
    await register(client, "eve@example.com", "correct")
    response = await client.post("/session", json={"email": "eve@example.com", "password": "wrong"})
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_logout_returns_200_with_valid_token(client: AsyncClient) -> None:
    token = await register(client, "frank@example.com")
    response = await client.delete("/session", headers=auth_header(token))
    assert response.status_code == 200


@pytest.mark.asyncio
async def test_logout_revokes_refresh_token(client: AsyncClient) -> None:
    access_token, refresh_token = await register_full(client, "revoker@example.com")
    import json as _json

    # httpx DELETE doesn't accept body kwargs; use request() instead
    logout_response = await client.request(
        "DELETE",
        "/session",
        headers={**auth_header(access_token), "Content-Type": "application/json"},
        content=_json.dumps({"refresh_token": refresh_token}),
    )
    assert logout_response.status_code == 200, logout_response.text
    # The revoked token must no longer work
    response = await client.post("/session/refresh", json={"refresh_token": refresh_token})
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_logout_returns_401_without_token(client: AsyncClient) -> None:
    response = await client.delete("/session")
    assert response.status_code == 401


# ── Refresh endpoint ──────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_refresh_returns_new_tokens(client: AsyncClient) -> None:
    _, refresh_token = await register_full(client, "refresher@example.com")
    response = await client.post("/session/refresh", json={"refresh_token": refresh_token})
    assert response.status_code == 200
    data = response.json()
    assert data["access_token"]
    assert data["refresh_token"]
    assert data["refresh_token"] != refresh_token  # token was rotated


@pytest.mark.asyncio
async def test_refresh_rotates_old_token(client: AsyncClient) -> None:
    _, refresh_token = await register_full(client, "rotate@example.com")
    # Use the refresh token once; it must succeed and return a new refresh token.
    first = await client.post("/session/refresh", json={"refresh_token": refresh_token})
    assert first.status_code == 200, first.text
    new_refresh_token = first.json()["refresh_token"]
    assert new_refresh_token != refresh_token
    # The old token must be rejected now
    response = await client.post("/session/refresh", json={"refresh_token": refresh_token})
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_refresh_returns_401_on_invalid_token(client: AsyncClient) -> None:
    response = await client.post("/session/refresh", json={"refresh_token": "not-a-real-token"})
    assert response.status_code == 401
