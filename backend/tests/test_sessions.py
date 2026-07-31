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


@pytest.mark.asyncio
async def test_refresh_rejection_carries_both_corroboration_signals(
    client: AsyncClient,
) -> None:
    """A rejected refresh must stay recognisable as *this* backend's answer.

    Clients treat a 401 from ``/session/refresh`` as the one authoritative reason to
    destroy a device's stored credentials, and a bare 401 from a captive portal or an
    intercepting proxy must not be able to do that.  So they corroborate the status
    code against two signals this handler emits: a JSON object body with a non-empty
    string ``detail`` (the primary — it is CORS-safe, and the browser hides response
    headers from the web build because ``CORSMiddleware`` exposes none), and
    ``WWW-Authenticate: Bearer`` as a fallback for an absent or unparseable body.

    That makes the response *shape* a two-sided contract.  Drop either signal — a
    FastAPI upgrade, a handler rewrite, a switch to a bare ``Response`` — and every
    client silently degrades to "never signs out", with nothing else failing.  Only
    the shape is asserted, never the wording: clients match on shape too, precisely
    so a copy edit here cannot flip their sign-out behaviour (ADR-0041, #606).
    """
    response = await client.post("/session/refresh", json={"refresh_token": "not-a-real-token"})

    assert response.status_code == 401
    body = response.json()
    assert isinstance(body, dict)
    assert isinstance(body.get("detail"), str)
    assert body["detail"]  # non-empty; an empty string corroborates nothing
    assert "bearer" in response.headers.get("www-authenticate", "").lower()


@pytest.mark.asyncio
async def test_refresh_rejection_of_a_revoked_token_carries_both_signals(
    client: AsyncClient,
) -> None:
    """The same contract on the rotation path, which is how a real device gets here.

    An unknown token is the easy case; a *revoked* one is the one an enrolled device
    meets after its refresh token has been rotated or its session signed out
    elsewhere, and it is raised from a different branch of the handler.
    """
    _, refresh_token = await register_full(client, "corroborate@example.com")
    first = await client.post("/session/refresh", json={"refresh_token": refresh_token})
    assert first.status_code == 200, first.text

    response = await client.post("/session/refresh", json={"refresh_token": refresh_token})

    assert response.status_code == 401
    body = response.json()
    assert isinstance(body, dict)
    assert isinstance(body.get("detail"), str)
    assert body["detail"]
    assert "bearer" in response.headers.get("www-authenticate", "").lower()
