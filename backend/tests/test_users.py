import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, register


@pytest.mark.asyncio
async def test_register_creates_user_and_returns_token(client: AsyncClient) -> None:
    response = await client.post("/user", json={"email": "alice@example.com", "password": "secret"})
    assert response.status_code == 201
    data = response.json()
    assert data["token_type"] == "bearer"
    assert data["access_token"]


@pytest.mark.asyncio
async def test_get_user_profile_with_valid_token(client: AsyncClient) -> None:
    token = await register(client, "bob@example.com")
    response = await client.get("/user", headers=auth_header(token))
    assert response.status_code == 200
    data = response.json()
    assert data["email"] == "bob@example.com"
    assert data["is_active"] is True


@pytest.mark.asyncio
async def test_get_user_profile_without_token_returns_401(client: AsyncClient) -> None:
    response = await client.get("/user")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_duplicate_email_returns_409(client: AsyncClient) -> None:
    await register(client, "carol@example.com")
    response = await client.post("/user", json={"email": "carol@example.com", "password": "other"})
    assert response.status_code == 409


@pytest.mark.asyncio
async def test_register_with_empty_email_returns_422(client: AsyncClient) -> None:
    response = await client.post("/user", json={"email": "", "password": "secret"})
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_register_with_whitespace_email_returns_422(client: AsyncClient) -> None:
    response = await client.post("/user", json={"email": "   ", "password": "secret"})
    assert response.status_code == 422
