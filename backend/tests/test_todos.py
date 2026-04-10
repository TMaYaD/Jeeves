import pytest
from httpx import AsyncClient

from tests.conftest import auth_header, register


@pytest.mark.asyncio
async def test_list_todos_requires_auth(client: AsyncClient) -> None:
    response = await client.get("/todos/")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_create_todo_requires_auth(client: AsyncClient) -> None:
    response = await client.post("/todos/", json={"title": "Buy milk"})
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_create_and_list_todos_with_valid_token(client: AsyncClient) -> None:
    token = await register(client, "grace@example.com")
    create_response = await client.post(
        "/todos/", json={"title": "Buy milk"}, headers=auth_header(token)
    )
    assert create_response.status_code == 201

    list_response = await client.get("/todos/", headers=auth_header(token))
    assert list_response.status_code == 200
    todos = list_response.json()
    assert len(todos) == 1
    assert todos[0]["title"] == "Buy milk"


@pytest.mark.asyncio
async def test_user_cannot_access_another_users_todo(client: AsyncClient) -> None:
    token_a = await register(client, "henry@example.com")
    token_b = await register(client, "iris@example.com")

    create_response = await client.post(
        "/todos/", json={"title": "Henry's private todo"}, headers=auth_header(token_a)
    )
    todo_id = create_response.json()["id"]

    response = await client.get(f"/todos/{todo_id}", headers=auth_header(token_b))
    assert response.status_code == 404
