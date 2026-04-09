"""End-to-end tests covering complete user journeys."""

import pytest
from httpx import AsyncClient

from tests.conftest import auth_header


@pytest.mark.asyncio
async def test_full_user_journey(client: AsyncClient) -> None:
    """Register -> login -> create todos -> list -> update -> delete -> verify."""

    # 1. Register
    reg = await client.post("/user", json={"email": "journey@example.com", "password": "s3cret"})
    assert reg.status_code == 201
    token = reg.json()["access_token"]
    headers = auth_header(token)

    # 2. Login with same credentials
    login = await client.post(
        "/session", json={"email": "journey@example.com", "password": "s3cret"}
    )
    assert login.status_code == 200
    login_token = login.json()["access_token"]
    login_headers = auth_header(login_token)

    # 3. View profile using login token
    profile = await client.get("/user", headers=login_headers)
    assert profile.status_code == 200
    assert profile.json()["email"] == "journey@example.com"

    # 4. Create two todos
    todo1 = await client.post("/todos/", json={"title": "Buy groceries"}, headers=headers)
    assert todo1.status_code == 201
    todo1_id = todo1.json()["id"]

    todo2 = await client.post(
        "/todos/", json={"title": "Walk the dog", "priority": 1}, headers=headers
    )
    assert todo2.status_code == 201

    # 5. List todos — should see both
    listing = await client.get("/todos/", headers=headers)
    assert listing.status_code == 200
    assert len(listing.json()) == 2

    # 6. Update first todo as completed
    update = await client.patch(f"/todos/{todo1_id}", json={"completed": True}, headers=headers)
    assert update.status_code == 200
    assert update.json()["completed"] is True

    # 7. Delete second todo
    todo2_id = todo2.json()["id"]
    delete = await client.delete(f"/todos/{todo2_id}", headers=headers)
    assert delete.status_code == 204

    # 8. Verify only one todo remains
    remaining = await client.get("/todos/", headers=headers)
    assert len(remaining.json()) == 1
    assert remaining.json()[0]["id"] == todo1_id

    # 9. Logout
    logout = await client.delete("/session", headers=headers)
    assert logout.status_code == 200


@pytest.mark.asyncio
async def test_multi_user_isolation(client: AsyncClient) -> None:
    """Two users cannot see or modify each other's data."""

    # Register two users
    reg_a = await client.post(
        "/user", json={"email": "alice-e2e@example.com", "password": "secret"}
    )
    reg_b = await client.post("/user", json={"email": "bob-e2e@example.com", "password": "secret"})
    headers_a = auth_header(reg_a.json()["access_token"])
    headers_b = auth_header(reg_b.json()["access_token"])

    # Alice creates a todo
    todo = await client.post("/todos/", json={"title": "Alice only"}, headers=headers_a)
    todo_id = todo.json()["id"]

    # Bob cannot read it
    get_resp = await client.get(f"/todos/{todo_id}", headers=headers_b)
    assert get_resp.status_code == 404

    # Bob cannot update it
    patch_resp = await client.patch(
        f"/todos/{todo_id}", json={"title": "Hacked"}, headers=headers_b
    )
    assert patch_resp.status_code == 404

    # Bob cannot delete it
    del_resp = await client.delete(f"/todos/{todo_id}", headers=headers_b)
    assert del_resp.status_code == 404

    # Bob's todo list is empty
    bob_list = await client.get("/todos/", headers=headers_b)
    assert bob_list.json() == []

    # Alice still sees her todo
    alice_list = await client.get("/todos/", headers=headers_a)
    assert len(alice_list.json()) == 1
