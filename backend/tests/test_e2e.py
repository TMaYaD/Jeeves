"""End-to-end tests covering complete user journeys."""

from datetime import datetime

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
    done_at_sent = "2026-01-01T00:00:00Z"
    update = await client.patch(
        f"/todos/{todo1_id}", json={"done_at": done_at_sent}, headers=headers
    )
    assert update.status_code == 200
    returned_done_at = update.json()["done_at"]
    assert datetime.fromisoformat(returned_done_at) == datetime.fromisoformat(done_at_sent)

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


# ── GTD E2E tests ─────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_project_tag_single_assignment(client: AsyncClient) -> None:
    """Assigning two project tags to the same todo is rejected with 422."""
    reg = await client.post(
        "/user", json={"email": "single-proj@example.com", "password": "secret"}
    )
    headers = auth_header(reg.json()["access_token"])

    resp = await client.post(
        "/todos/",
        json={
            "title": "Ambiguous task",
            "tags": [
                {"name": "ProjectAlpha", "type": "project"},
                {"name": "ProjectBeta", "type": "project"},
            ],
        },
        headers=headers,
    )
    assert resp.status_code == 422
    assert "project" in resp.json()["detail"].lower()


@pytest.mark.asyncio
async def test_due_date_accepts_drift_local_tz_format(client: AsyncClient) -> None:
    """PowerSync uploads due_date in Drift's local-tz format with a space
    before the offset (e.g. '2026-04-30T00:00:00.000 +05:30').  That format
    is non-standard ISO 8601 but is what Drift produces when
    `storeDateTimeAsText` is enabled and the DateTime is local.  We must
    accept it — otherwise PowerSync's CRUD queue gets stuck retrying a
    poisoned PATCH and the sync indicator goes red."""
    reg = await client.post("/user", json={"email": "due-date@example.com", "password": "s3cret"})
    headers = auth_header(reg.json()["access_token"])

    create = await client.post("/todos/", json={"title": "Reschedule me"}, headers=headers)
    todo_id = create.json()["id"]

    drift_format = "2026-04-30T00:00:00.000 +05:30"
    expected_instant = datetime.fromisoformat("2026-04-30T00:00:00+05:30")
    patch = await client.patch(
        f"/todos/{todo_id}", json={"due_date": drift_format}, headers=headers
    )
    assert patch.status_code == 200, patch.text
    assert datetime.fromisoformat(patch.json()["due_date"]) == expected_instant

    # POST should also accept it.
    posted = await client.post(
        "/todos/", json={"title": "Plan now", "due_date": drift_format}, headers=headers
    )
    assert posted.status_code == 201, posted.text
    assert datetime.fromisoformat(posted.json()["due_date"]) == expected_instant
