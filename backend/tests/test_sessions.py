import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, register


@pytest.mark.asyncio
async def test_login_returns_token_on_valid_credentials(client: AsyncClient) -> None:
    await register(client, "dan@example.com", "mypassword")
    response = await client.post(
        "/session", json={"email": "dan@example.com", "password": "mypassword"}
    )
    assert response.status_code == 200
    data = response.json()
    assert data["token_type"] == "bearer"
    assert data["access_token"]


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
async def test_logout_returns_401_without_token(client: AsyncClient) -> None:
    response = await client.delete("/session")
    assert response.status_code == 401
