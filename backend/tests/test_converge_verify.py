"""The converge-verify endpoints (#553 Phase 1, issue #582).

Cutover tooling — removed by #556.

Every assertion here is about what the *device* will conclude from the payload:
that it only ever sees its own rows, that a second call says the same thing, that
a NULL-id junction row is counted rather than crashing the report, and that the
detail route can turn a digest mismatch into a column-level diff.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from httpx import AsyncClient
from sqlalchemy import insert, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.models import User
from app.converge_verify.canonical import CANONICAL_ROW_MANIFEST, canonical_row
from app.converge_verify.routes import MAX_ROW_DETAIL_IDS
from app.todos.models import (
    Action,
    Capture,
    CaptureOutcome,
    CaptureTag,
    FocusSession,
    FocusSessionDisposition,
    FocusSessionTask,
    Tag,
    TimeLog,
    Todo,
    TodoTag,
    UserPreference,
)

from .conftest import register

CREATED = datetime(2026, 4, 29, 3, 45, tzinfo=UTC)


async def _user_id(db: AsyncSession, email: str) -> str:
    result = await db.execute(select(User).where(User.email == email))
    return result.scalar_one().id


async def _seed_todo(db: AsyncSession, *, user_id: str, todo_id: str, title: str) -> Todo:
    todo = Todo(
        id=todo_id,
        title=title,
        user_id=user_id,
        created_at=CREATED,
        clarified=True,
        intent="next",
        time_spent_minutes=0,
    )
    db.add(todo)
    await db.commit()
    return todo


async def test_report_contains_only_the_callers_rows(client: AsyncClient, db: AsyncSession) -> None:
    mine = await register(client, "mine@example.com")
    await register(client, "theirs@example.com")
    my_id = await _user_id(db, "mine@example.com")
    their_id = await _user_id(db, "theirs@example.com")

    await _seed_todo(db, user_id=my_id, todo_id="todo-mine", title="Mine")
    await _seed_todo(db, user_id=their_id, todo_id="todo-theirs", title="Theirs")

    response = await client.get(
        "/converge-verify/report", headers={"Authorization": f"Bearer {mine}"}
    )
    assert response.status_code == 200
    todos = response.json()["tables"]["todos"]
    assert todos["count"] == 1
    assert list(todos["rows"]) == ["todo-mine"]


async def test_report_digests_match_the_canonical_serialiser(
    client: AsyncClient, db: AsyncSession
) -> None:
    """The endpoint's digest is the vector-pinned one, not a second recipe."""
    token = await register(client, "digest@example.com")
    user_id = await _user_id(db, "digest@example.com")
    await _seed_todo(db, user_id=user_id, todo_id="todo-1", title="Ship it")

    response = await client.get(
        "/converge-verify/report", headers={"Authorization": f"Bearer {token}"}
    )
    expected = canonical_row(
        "todos",
        {
            "capture_source": None,
            "clarified": True,
            "created_at": CREATED,
            "done_at": None,
            "due_date": None,
            "energy_level": None,
            "id": "todo-1",
            "intent": "next",
            "last_clarified_at": None,
            "last_next_action_completion_at": None,
            "location_id": None,
            "notes": None,
            "priority": None,
            "time_estimate": None,
            "title": "Ship it",
            "updated_at": None,
        },
    )
    assert response.json()["tables"]["todos"]["rows"]["todo-1"] == expected.digest


async def test_report_covers_every_synced_table_and_names_the_exclusions(
    client: AsyncClient,
) -> None:
    token = await register(client, "shape@example.com")
    body = (
        await client.get("/converge-verify/report", headers={"Authorization": f"Bearer {token}"})
    ).json()

    assert set(body["tables"]) == set(CANONICAL_ROW_MANIFEST)
    for table in body["tables"].values():
        assert table == {"count": 0, "null_id_row_count": 0, "rows": {}, "anomalies": []}
    # The reviewer must be able to see what the verdict deliberately ignores.
    assert body["excluded_columns"]["*"] == ["user_id"]
    assert body["excluded_columns"]["todos"] == ["time_spent_minutes"]
    assert body["spec_version"] == 1
    assert body["server_version"] == "1.2.3-test"
    assert body["generated_at"].endswith("Z")


async def test_two_consecutive_reports_are_byte_identical(
    client: AsyncClient, db: AsyncSession
) -> None:
    """Repeatability is an acceptance criterion; only the run timestamp may move."""
    token = await register(client, "repeat@example.com")
    user_id = await _user_id(db, "repeat@example.com")
    for index in range(3):
        await _seed_todo(db, user_id=user_id, todo_id=f"todo-{index}", title=f"T{index}")
    db.add(Tag(id="tag-1", name="@work", type="context", user_id=user_id))
    db.add(TodoTag(id="tt-1", todo_id="todo-0", tag_id="tag-1", user_id=user_id))
    await db.commit()

    headers = {"Authorization": f"Bearer {token}"}
    first = await client.get("/converge-verify/report", headers=headers)
    second = await client.get("/converge-verify/report", headers=headers)
    assert first.json()["tables"] == second.json()["tables"]


async def test_report_requires_authentication(client: AsyncClient) -> None:
    assert (await client.get("/converge-verify/report")).status_code == 401
    assert (await client.get("/converge-verify/rows?table=todos")).status_code == 401


async def test_null_id_junction_row_is_counted_not_crashed(
    client: AsyncClient, db: AsyncSession
) -> None:
    """Postgres fills junction ``id`` by default, but NULL is representable.

    Such a row has no identity to match against the device, so it cannot enter
    the digest map — and per the plan review its presence must be visible enough
    to force a non-converged verdict, which is what ``null_id_row_count`` is for.
    """
    token = await register(client, "nullid@example.com")
    user_id = await _user_id(db, "nullid@example.com")
    await _seed_todo(db, user_id=user_id, todo_id="todo-0", title="T")
    db.add(Tag(id="tag-1", name="@work", type="context", user_id=user_id))
    await db.commit()
    # A server-side insert with no id — exactly what a pre-0006 row looks like.
    await db.execute(
        insert(TodoTag).values(id=None, todo_id="todo-0", tag_id="tag-1", user_id=user_id)
    )
    await db.commit()

    body = (
        await client.get("/converge-verify/report", headers={"Authorization": f"Bearer {token}"})
    ).json()
    junction = body["tables"]["todo_tags"]
    assert junction["count"] == 1
    assert junction["null_id_row_count"] == 1
    assert junction["rows"] == {}


async def test_report_survives_a_row_the_manifest_refuses(
    client: AsyncClient, db: AsyncSession
) -> None:
    """A value the manifest's kind refuses degrades to an anomaly, never a 500.

    A throw here would brick the report on the only device that matters, which is
    why the serialiser has no exception path at all.  A text value in an integer
    column is the refusal a SQLite-backed suite can actually reach — a bad
    timestamp is rejected by both the SQLite `DateTime` type and Postgres
    `timestamptz`, so on the server side that refusal is structurally unreachable
    and is covered where it can occur: the golden vectors, which is also where the
    device-side text store's shapes are pinned.
    """
    token = await register(client, "anomaly@example.com")
    user_id = await _user_id(db, "anomaly@example.com")
    await _seed_todo(db, user_id=user_id, todo_id="todo-0", title="T")
    # text() so SQLAlchemy's bind processor does not sanitise the value on the way
    # in — the point is a stored value the manifest will refuse on the way out.
    await db.execute(
        text("UPDATE todos SET priority = 'high' WHERE id = :row_id"),
        {"row_id": "todo-0"},
    )
    await db.commit()

    response = await client.get(
        "/converge-verify/report", headers={"Authorization": f"Bearer {token}"}
    )
    assert response.status_code == 200
    todos = response.json()["tables"]["todos"]
    assert todos["count"] == 1
    assert todos["anomalies"] == [
        {
            "row_id": "todo-0",
            "column": "priority",
            "kind": "invalid_integer",
            "raw": "high",
        }
    ]
    # The row still carries a digest, so the differ can still place it — an
    # anomaly narrows trust in one column, it does not erase the row.
    assert "todo-0" in todos["rows"]


async def test_report_covers_a_row_in_every_table(client: AsyncClient, db: AsyncSession) -> None:
    """One populated row per table, so no table's SELECT is only ever run empty."""
    token = await register(client, "populated@example.com")
    user_id = await _user_id(db, "populated@example.com")
    await _seed_todo(db, user_id=user_id, todo_id="todo-0", title="T")
    db.add(Tag(id="tag-1", name="@work", type="context", user_id=user_id))
    db.add(TodoTag(id="tt-1", todo_id="todo-0", tag_id="tag-1", user_id=user_id))
    db.add(
        Action(
            id="action-1",
            outcome_id="todo-0",
            user_id=user_id,
            text="Draft it",
            role="current",
            created_at=CREATED,
        )
    )
    db.add(FocusSession(id="fs-1", user_id=user_id, started_at=CREATED))
    db.add(
        TimeLog(
            id="tl-1",
            user_id=user_id,
            task_id="todo-0",
            action_id="action-1",
            started_at=CREATED,
            focus_session_id="fs-1",
        )
    )
    db.add(UserPreference(id="pref-1", user_id=user_id, key="k", value="1", updated_at=CREATED))
    db.add(Capture(id="cap-1", title="Call the plumber", user_id=user_id, created_at=CREATED))
    db.add(
        CaptureOutcome(
            id="co-1",
            capture_id="cap-1",
            outcome_id="todo-0",
            created_at=CREATED,
            user_id=user_id,
        )
    )
    db.add(CaptureTag(id="ct-1", capture_id="cap-1", tag_id="tag-1", user_id=user_id))
    db.add(
        FocusSessionTask(
            id="fst-1",
            focus_session_id="fs-1",
            task_id="todo-0",
            position=0,
            disposition="rollover",
            user_id=user_id,
        )
    )
    db.add(
        FocusSessionDisposition(
            id="fsd-1",
            focus_session_id="fs-1",
            task_id="todo-0",
            disposition="maybe",
            user_id=user_id,
        )
    )
    await db.commit()

    body = (
        await client.get("/converge-verify/report", headers={"Authorization": f"Bearer {token}"})
    ).json()
    populated = {name for name, table in body["tables"].items() if table["count"] > 0}
    assert populated == {
        "todos",
        "tags",
        "todo_tags",
        "actions",
        "focus_sessions",
        "time_logs",
        "focus_session_tasks",
        "focus_session_dispositions",
        "user_preferences",
        "captures",
        "capture_outcomes",
        "capture_tags",
    }
    for name in populated:
        table = body["tables"][name]
        assert table["anomalies"] == [], name
        assert len(table["rows"]) == table["count"], name


# --- the detail route --------------------------------------------------------


async def test_rows_returns_canonical_strings_for_named_ids(
    client: AsyncClient, db: AsyncSession
) -> None:
    token = await register(client, "detail@example.com")
    user_id = await _user_id(db, "detail@example.com")
    await _seed_todo(db, user_id=user_id, todo_id="todo-0", title="Ship it")
    await _seed_todo(db, user_id=user_id, todo_id="todo-1", title="Other")

    body = (
        await client.get(
            "/converge-verify/rows?table=todos&ids=todo-0&ids=nope",
            headers={"Authorization": f"Bearer {token}"},
        )
    ).json()
    assert list(body["rows"]) == ["todo-0"]
    assert body["missing_ids"] == ["nope"]
    # The canonical string is what makes a digest mismatch legible column by
    # column, so it must be the literal serialisation, not a summary of it.
    assert '"Ship it"' in body["rows"]["todo-0"]
    assert body["rows"]["todo-0"].startswith("[")


async def test_rows_will_not_reveal_another_users_row(
    client: AsyncClient, db: AsyncSession
) -> None:
    mine = await register(client, "a@example.com")
    await register(client, "b@example.com")
    their_id = await _user_id(db, "b@example.com")
    await _seed_todo(db, user_id=their_id, todo_id="todo-theirs", title="Theirs")

    body = (
        await client.get(
            "/converge-verify/rows?table=todos&ids=todo-theirs",
            headers={"Authorization": f"Bearer {mine}"},
        )
    ).json()
    assert body["rows"] == {}
    assert body["missing_ids"] == ["todo-theirs"]


async def test_rows_rejects_an_unknown_table(client: AsyncClient) -> None:
    token = await register(client, "unknown@example.com")
    response = await client.get(
        "/converge-verify/rows?table=sync_dead_letters&ids=x",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 404


async def test_rows_refuses_more_ids_than_the_cap(client: AsyncClient) -> None:
    """A refusal, not a silent truncation — a truncated answer reads as convergence."""
    token = await register(client, "cap@example.com")
    ids = "&".join(f"ids=id-{index}" for index in range(MAX_ROW_DETAIL_IDS + 1))
    response = await client.get(
        f"/converge-verify/rows?table=todos&{ids}",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert response.status_code == 400

    at_cap = "&".join(f"ids=id-{index}" for index in range(MAX_ROW_DETAIL_IDS))
    assert (
        await client.get(
            f"/converge-verify/rows?table=todos&{at_cap}",
            headers={"Authorization": f"Bearer {token}"},
        )
    ).status_code == 200


async def test_rows_takes_each_id_verbatim(client: AsyncClient, db: AsyncSession) -> None:
    """An id is opaque data, so the detail route must not re-interpret it.

    A comma, a space or an ``&`` inside an id used to split or truncate the
    request, and a row the server does have then read as "only on this device" —
    a wrong conclusion about the data, which is the one thing this tool must not
    reach.
    """
    token = await register(client, "verbatim@example.com")
    user_id = await _user_id(db, "verbatim@example.com")
    odd_id = " a,b&c d "
    await _seed_todo(db, user_id=user_id, todo_id=odd_id, title="Odd")

    body = (
        await client.get(
            "/converge-verify/rows",
            params={"table": "todos", "ids": [odd_id]},
            headers={"Authorization": f"Bearer {token}"},
        )
    ).json()
    assert list(body["rows"]) == [odd_id]
    assert body["missing_ids"] == []


async def test_rows_carries_the_empty_string_id(client: AsyncClient, db: AsyncSession) -> None:
    """The empty string is an id, not an absence.

    The report emits it as a key like any other — only a NULL id becomes
    ``null_id_row_count``, on both sides — so a detail route that filtered it out
    would report a row the server does have as missing, and the device would read
    the two answers as a divergence.
    """
    token = await register(client, "emptyid@example.com")
    user_id = await _user_id(db, "emptyid@example.com")
    await _seed_todo(db, user_id=user_id, todo_id="", title="Blank id")
    headers = {"Authorization": f"Bearer {token}"}

    report = (await client.get("/converge-verify/report", headers=headers)).json()
    assert list(report["tables"]["todos"]["rows"]) == [""]
    assert report["tables"]["todos"]["null_id_row_count"] == 0

    body = (
        await client.get(
            "/converge-verify/rows",
            params={"table": "todos", "ids": [""]},
            headers=headers,
        )
    ).json()
    assert list(body["rows"]) == [""]
    assert body["missing_ids"] == []


async def test_rows_with_no_ids_is_an_empty_answer(client: AsyncClient) -> None:
    token = await register(client, "empty@example.com")
    body = (
        await client.get(
            "/converge-verify/rows?table=todos",
            headers={"Authorization": f"Bearer {token}"},
        )
    ).json()
    assert body == {"table": "todos", "rows": {}, "missing_ids": []}


async def test_the_report_writes_nothing(client: AsyncClient, db: AsyncSession) -> None:
    """Read-only by effect: the rows the report describes are unchanged after it."""
    token = await register(client, "readonly@example.com")
    user_id = await _user_id(db, "readonly@example.com")
    await _seed_todo(db, user_id=user_id, todo_id="todo-0", title="T")

    async def snapshot() -> list[Any]:
        result = await db.execute(select(Todo.__table__).order_by(Todo.id))
        return [tuple(row) for row in result.all()]

    before = await snapshot()
    headers = {"Authorization": f"Bearer {token}"}
    await client.get("/converge-verify/report", headers=headers)
    await client.get("/converge-verify/rows?table=todos&ids=todo-0", headers=headers)
    assert await snapshot() == before
