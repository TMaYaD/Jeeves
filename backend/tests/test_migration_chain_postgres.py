"""The real migration chain, run base → head against a real Postgres with data.

Every other migration test in this suite drives a migration's ``upgrade()``
by hand against synthetic SQLite tables.  That is fast and it pins semantics,
but it cannot see anything that only exists in the production stack: Postgres'
own type deduction, asyncpg's prepared statements, ``alembic upgrade`` walking
the revisions in order.  Migration 0028 shipped an ``INSERT ... SELECT`` that
bound one parameter twice — as a bare value in the SELECT list (deduced
``text``) and against ``actions.id`` (deduced ``character varying``) — and
Postgres refused it: ``AmbiguousParameterError: inconsistent types deduced for
parameter $1``.  Backend CD failed on it five deploys running.

Backend CI already ran ``python -m app.migrate`` against a real Postgres and
stayed green throughout, because that database is **empty**: with no ``todos``
row carrying a non-blank ``next_action_text``, 0028's backfill loop never
executes, so the offending statement is never prepared and the migration
"passes".  An empty database is not a weaker version of this test — for a
data-backfill migration it exercises none of it.

So this module seeds representative rows at the revision *before* the backfill
and then continues to head.  Alembic runs in a subprocess against a scratch
database, which is what makes it faithful: the same ``alembic upgrade`` entry
point, the same ``alembic/env.py``, the same asyncpg driver that production
uses, rather than an in-process re-implementation of them.
"""

import asyncio
import os
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

asyncpg = pytest.importorskip("asyncpg")

_BACKEND_DIR = Path(__file__).resolve().parents[1]

# The scratch database is created and dropped by this module.  It is deliberately
# NOT the suite's own database: CI migrates that one to head before pytest runs,
# and this test needs to start from an empty schema.
_SCRATCH_DB = "jeeves_migration_chain_test"

# The revision immediately before 0028.  Seeding happens here because `todos`
# must already exist to hold the rows whose shape triggers the backfill.
_SEED_AT_REVISION = "0027"

# The last revision at which the mirrored domain tables still exist: 0034 drops
# all fifteen of them (#556).  Every assertion below that reads `todos` or
# `actions` stops here rather than at head — not to dodge the drop, but because
# those assertions are about 0028's backfill semantics, which are a statement
# about the schema while the mirror was live.  The drop itself is asserted
# separately, at head, by the two tests at the end of this module.
_LAST_MIRRORED_REVISION = "0033"

# Head after 0034.  Spelled out so adding a revision without deciding what it
# means for the drop assertions fails this test rather than silently moving.
_HEAD_REVISION = "0035"

# Dropped by 0034, children first (the migration's own order).
_MIRRORED_TABLES = (
    "todo_tags",
    "capture_tags",
    "capture_outcomes",
    "focus_session_dispositions",
    "focus_session_tasks",
    "time_logs",
    "reminders",
    "recurrence_rules",
    "actions",
    "focus_sessions",
    "captures",
    "todos",
    "tags",
    "locations",
    "user_preferences",
)

# Server-owned and therefore untouched by 0034: the op log and Member registry
# (0031), the identity-root escrow (0032), Workspaces and Grants (0033), and
# auth's own two tables.  The op log *is* the data now — a drop migration that
# clipped any of these would be the failure this list exists to catch.
_SERVER_OWNED_TABLES = (
    "ops",
    "members",
    "workspaces",
    "grants",
    "recovery_escrows",
    "recovery_escrow_fetches",
    "users",
    "refresh_tokens",
    "alembic_version",
)

_OUTCOME_WITH_CURSOR = "chain-todo-with-cursor"
_OUTCOME_WITHOUT_CLARIFIED_AT = "chain-todo-fallback"
_OUTCOME_BLANK_CURSOR = "chain-todo-blank-cursor"
_OUTCOME_NULL_CURSOR = "chain-todo-null-cursor"

# Seeded only in the re-entry test, *after* 0028 has already run once: its
# Action can therefore only exist if the backfill genuinely re-executed.
_OUTCOME_ADDED_AFTER_FIRST_BACKFILL = "chain-todo-added-after-first-backfill"

# uuid5(NAMESPACE_URL, "jeeves://action/backfill/<todo_id>") — the deterministic
# ids 0028 mints.  Spelled out rather than recomputed with the migration's own
# helper so a change to that helper fails this test instead of moving with it.
_BACKFILL_IDS = {
    _OUTCOME_WITH_CURSOR: "9565a928-0420-5407-bbc5-cf40a43c8a29",
    _OUTCOME_WITHOUT_CLARIFIED_AT: "5572bb54-7f88-5cf9-b8a1-39b30dc21adc",
}
_LATE_BACKFILL_ID = "3c95d34b-e517-5173-8309-de0deb726220"

# The cursor text 0028 derives _OUTCOME_WITH_CURSOR's Action from, and the text a
# device writes over it while the server cannot accept Action uploads.  They must
# differ for the "client edit survives re-entry" assertion to mean anything.
_CURSOR_TEXT = "Email Bob about the contract"
_CLIENT_EDITED_TEXT = "edited by a client during the outage"


def _database_url() -> str:
    """The Postgres URL to build the scratch database beside, or skip.

    Read from the environment rather than ``app.config.settings`` on purpose:
    settings supplies a localhost default when DATABASE_URL is unset, which
    would turn "no Postgres here" into a connection error instead of a skip.
    """
    url = os.environ.get("DATABASE_URL", "")
    if "postgres" not in url:
        # In CI a missing Postgres is the bug this module exists to prevent
        # (a silently skipped migration test is how the outage stayed
        # invisible), so fail there rather than skip.
        if os.environ.get("CI"):
            pytest.fail(
                "DATABASE_URL must point at Postgres in CI — this test is the "
                "only coverage of the real migration chain and must not skip."
            )
        pytest.skip("requires a Postgres DATABASE_URL")
    return url


def _asyncpg_dsn(url: str, database: str) -> str:
    """Rewrite a SQLAlchemy URL into a plain asyncpg DSN for `database`."""
    scheme, _, rest = url.partition("://")
    scheme = scheme.replace("+asyncpg", "")
    host_part = rest.rpartition("/")[0] or rest
    return f"{scheme}://{host_part}/{database}"


async def _execute(dsn: str, statements: list[str]) -> None:
    conn = await asyncpg.connect(dsn)
    try:
        for statement in statements:
            await conn.execute(statement)
    finally:
        await conn.close()


async def _fetch(dsn: str, query: str) -> list[dict[str, Any]]:
    conn = await asyncpg.connect(dsn)
    try:
        return [dict(record) for record in await conn.fetch(query)]
    finally:
        await conn.close()


@pytest.fixture
def scratch_database() -> Iterator[str]:
    """An empty Postgres database, dropped when the test finishes."""
    url = _database_url()
    admin_dsn = _asyncpg_dsn(url, "postgres")
    scratch_dsn = _asyncpg_dsn(url, _SCRATCH_DB)

    # CREATE/DROP DATABASE cannot run inside a transaction block, hence the
    # bare connection rather than the suite's session fixtures.
    asyncio.run(
        _execute(
            admin_dsn,
            [
                f'DROP DATABASE IF EXISTS "{_SCRATCH_DB}" WITH (FORCE)',
                f'CREATE DATABASE "{_SCRATCH_DB}"',
            ],
        )
    )
    try:
        yield scratch_dsn
    finally:
        asyncio.run(_execute(admin_dsn, [f'DROP DATABASE IF EXISTS "{_SCRATCH_DB}" WITH (FORCE)']))


def _alembic(command: str, revision: str, scratch_dsn: str) -> subprocess.CompletedProcess[str]:
    """Run ``alembic <command> <revision>`` exactly as the release phase does."""
    env = {
        **os.environ,
        # env.py reads settings.database_url, which is built from this.
        "DATABASE_URL": scratch_dsn.replace("postgresql://", "postgresql+asyncpg://"),
        "SECRET_KEY": "migration-chain-test-secret",
    }
    return subprocess.run(
        [sys.executable, "-m", "alembic", command, revision],
        cwd=_BACKEND_DIR,
        env=env,
        capture_output=True,
        text=True,
    )


def _upgrade(revision: str, scratch_dsn: str) -> None:
    result = _alembic("upgrade", revision, scratch_dsn)
    assert result.returncode == 0, (
        f"alembic upgrade {revision} failed\n"
        f"--- stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}"
    )


async def _seed_representative_rows(dsn: str) -> None:
    """Rows covering every branch of 0028's backfill predicate.

    The two qualifying Outcomes are what make this test able to fail: without a
    non-blank ``next_action_text`` the backfill loop body never runs.
    """
    conn = await asyncpg.connect(dsn)
    try:
        await conn.execute(
            "INSERT INTO users (id, email, hashed_password, created_at) "
            "VALUES ('chain-user', 'chain@example.com', 'x', now())"
        )
        await conn.execute(
            "INSERT INTO todos (id, title, user_id, created_at, intent, clarified, "
            "                   time_spent_minutes, next_action_text, energy_level, "
            "                   time_estimate, last_clarified_at) "
            "VALUES ($1, 'Ship the thing', 'chain-user', now(), 'next', true, 0, "
            "        $2, 'high', 30, now())",
            _OUTCOME_WITH_CURSOR,
            _CURSOR_TEXT,
        )
        # No last_clarified_at: exercises the created_at fallback.
        await conn.execute(
            "INSERT INTO todos (id, title, user_id, created_at, intent, clarified, "
            "                   time_spent_minutes, next_action_text) "
            "VALUES ($1, 'Fallback', 'chain-user', now(), 'next', true, 0, "
            "        'Call the plumber')",
            _OUTCOME_WITHOUT_CLARIFIED_AT,
        )
        # Actionless: whitespace-only and NULL must mint nothing.
        await conn.execute(
            "INSERT INTO todos (id, title, user_id, created_at, intent, clarified, "
            "                   time_spent_minutes, next_action_text) "
            "VALUES ($1, 'Blank', 'chain-user', now(), 'next', true, 0, '   ')",
            _OUTCOME_BLANK_CURSOR,
        )
        await conn.execute(
            "INSERT INTO todos (id, title, user_id, created_at, intent, clarified, "
            "                   time_spent_minutes, next_action_text) "
            "VALUES ($1, 'No cursor', 'chain-user', now(), 'next', true, 0, NULL)",
            _OUTCOME_NULL_CURSOR,
        )
    finally:
        await conn.close()


def test_chain_reaches_head_with_seeded_data(scratch_database: str) -> None:
    """base → 0027 → (seed) → head, against real Postgres over asyncpg.

    This is the assertion Backend CD makes on every deploy, and the one no
    test made before: that the pending revisions apply to a database that
    actually contains user rows.
    """
    _upgrade(_SEED_AT_REVISION, scratch_database)
    asyncio.run(_seed_representative_rows(scratch_database))

    _upgrade("head", scratch_database)

    stamped = asyncio.run(_fetch(scratch_database, "SELECT version_num FROM alembic_version"))
    assert stamped == [{"version_num": _HEAD_REVISION}]


def test_backfill_mints_one_current_action_per_non_blank_cursor(
    scratch_database: str,
) -> None:
    """0028's backfill, verified on the rows Postgres actually stored."""
    _upgrade(_SEED_AT_REVISION, scratch_database)
    asyncio.run(_seed_representative_rows(scratch_database))
    _upgrade(_LAST_MIRRORED_REVISION, scratch_database)

    actions = asyncio.run(
        _fetch(
            scratch_database,
            "SELECT id, outcome_id, user_id, text, role, position, energy_level, "
            "       time_estimate, done_at "
            "FROM actions ORDER BY outcome_id",
        )
    )

    assert [action["outcome_id"] for action in actions] == [
        _OUTCOME_WITHOUT_CLARIFIED_AT,
        _OUTCOME_WITH_CURSOR,
    ]
    assert [action["id"] for action in actions] == [
        _BACKFILL_IDS[_OUTCOME_WITHOUT_CLARIFIED_AT],
        _BACKFILL_IDS[_OUTCOME_WITH_CURSOR],
    ]
    assert all(action["role"] == "current" for action in actions)
    assert all(action["position"] is None and action["done_at"] is None for action in actions)

    with_cursor = actions[1]
    assert with_cursor["text"] == _CURSOR_TEXT
    assert with_cursor["energy_level"] == "high"
    assert with_cursor["time_estimate"] == 30
    assert with_cursor["user_id"] == "chain-user"


def test_rerunning_upgrade_is_a_no_op(scratch_database: str) -> None:
    """ADR-0012's re-runnable contract, exercised against real Postgres.

    A second ``upgrade`` must neither fail nor duplicate backfilled rows — the
    guard 0028 relies on for drift recovery and for runs that land after clients
    have already uploaded their own backfill Actions (ADR-0019).  Both passes
    stop at the last mirrored revision so ``actions`` is still there to count;
    re-runnability at head is covered by the drop test below.
    """
    _upgrade(_SEED_AT_REVISION, scratch_database)
    asyncio.run(_seed_representative_rows(scratch_database))
    _upgrade(_LAST_MIRRORED_REVISION, scratch_database)

    _upgrade(_LAST_MIRRORED_REVISION, scratch_database)

    actions = asyncio.run(_fetch(scratch_database, "SELECT id FROM actions"))
    assert len(actions) == len(_BACKFILL_IDS)


def test_0028_backfill_reapplied_over_existing_rows_is_a_no_op(
    scratch_database: str,
) -> None:
    """0028's backfill re-entered while its rows already exist — the guard's real job.

    **Why the stamp is rewritten rather than downgraded.**  There is no
    downgrade path back across 0028: its ``downgrade()`` raises on purpose
    (dropping ``actions`` would destroy client-uploaded rows).  ``alembic
    downgrade 0028`` therefore stops *at* 0028 without ever invoking it and
    leaves the stamp reading ``0028``, so the next ``upgrade head`` skips the
    revision entirely and the backfill never re-runs.  The only way in is to
    move the *stamp* rather than the schema: rewrite ``alembic_version`` to
    0027 by raw SQL while leaving ``actions`` and every row in it untouched.
    That is precisely the drift ADR-0012's re-runnable contract exists for — a
    stamp that under-reports what the schema already holds — and it is the
    shape of the production recovery this migration has to survive.

    **Why the first pass stops at 0028.**  0030 drops
    ``todos.next_action_text``, which 0028's backfill reads; re-entry has to
    happen while the source column is still there, exactly as it would inside a
    single 0027 → head deploy.

    **Why a late Outcome is seeded.**  Without it a passing test could not
    distinguish "the guard held" from "the backfill never ran" — the failure
    mode this test previously had.  ``_OUTCOME_ADDED_AFTER_FIRST_BACKFILL`` is
    inserted after 0028's first pass, so its Action can only exist if the
    backfill genuinely re-executed.
    """
    _upgrade(_SEED_AT_REVISION, scratch_database)
    asyncio.run(_seed_representative_rows(scratch_database))
    # Stop at 0028, not head: 0030 drops the column the backfill reads.
    _upgrade("0028", scratch_database)

    # The outage scenario: a device edits its locally-minted Action — the same
    # deterministic id 0028 mints — while the server cannot accept the upload.
    # The Outcome's cursor still holds the pre-outage text.  A re-entered
    # backfill must not push that stale text back over the edit.
    asyncio.run(
        _execute(
            scratch_database,
            [
                f"UPDATE actions SET text = '{_CLIENT_EDITED_TEXT}' "
                f"WHERE outcome_id = '{_OUTCOME_WITH_CURSOR}'",
                # An Outcome that appears only after the first backfill: proof
                # that the second pass actually enters the loop body.
                "INSERT INTO todos (id, title, user_id, created_at, intent, clarified, "
                "                   time_spent_minutes, next_action_text) "
                f"VALUES ('{_OUTCOME_ADDED_AFTER_FIRST_BACKFILL}', 'Late arrival', "
                "        'chain-user', now(), 'next', true, 0, 'Book the venue')",
            ],
        )
    )

    # The edit and the cursor it derives from must actually disagree, or the
    # survival assertion below would hold no matter what the migration does.
    source = asyncio.run(
        _fetch(
            scratch_database,
            "SELECT t.next_action_text AS cursor_text, a.text AS action_text "
            "FROM todos t JOIN actions a ON a.outcome_id = t.id "
            f"WHERE t.id = '{_OUTCOME_WITH_CURSOR}'",
        )
    )
    assert source == [{"cursor_text": _CURSOR_TEXT, "action_text": _CLIENT_EDITED_TEXT}]

    # Force re-entry: the stamp goes back to 0027, the data stays put.
    asyncio.run(_execute(scratch_database, ["UPDATE alembic_version SET version_num = '0027'"]))
    _upgrade(_LAST_MIRRORED_REVISION, scratch_database)

    actions = asyncio.run(
        _fetch(scratch_database, "SELECT id, outcome_id, text FROM actions ORDER BY outcome_id")
    )
    by_outcome = {action["outcome_id"]: action for action in actions}

    # The backfill really did re-execute: the late Outcome got its Action.
    assert _OUTCOME_ADDED_AFTER_FIRST_BACKFILL in by_outcome
    assert by_outcome[_OUTCOME_ADDED_AFTER_FIRST_BACKFILL]["id"] == _LATE_BACKFILL_ID
    assert by_outcome[_OUTCOME_ADDED_AFTER_FIRST_BACKFILL]["text"] == "Book the venue"

    # 1. ON CONFLICT (id) DO NOTHING held: re-entry minted no duplicates.  The
    #    pre-existing Outcomes still have exactly one Action each, on the same
    #    deterministic ids as before.
    assert len(actions) == len(_BACKFILL_IDS) + 1
    for outcome_id, backfill_id in _BACKFILL_IDS.items():
        assert by_outcome[outcome_id]["id"] == backfill_id

    # 2. DO NOTHING, not DO UPDATE: the device's edit is still there, and the
    #    stale cursor text was not written back over it.
    assert by_outcome[_OUTCOME_WITH_CURSOR]["text"] == _CLIENT_EDITED_TEXT
    assert by_outcome[_OUTCOME_WITH_CURSOR]["text"] != _CURSOR_TEXT


# --- 0034: the mirrored schema drop (#556) ----------------------------------


def test_head_drops_every_mirrored_table_and_keeps_the_server_owned_ones(
    scratch_database: str,
) -> None:
    """0034 removes the mirror and nothing else, over real rows.

    An empty database cannot distinguish "the drop worked" from "there was
    nothing to drop", and it cannot exercise the FK-safe ordering at all — a
    child dropped after its parent raises on Postgres and only on Postgres.  So
    this seeds the mirror at 0027, walks to head, and then asserts both halves
    of the migration's contract: all fifteen mirrored tables gone, all nine
    server-owned tables still there.  The op log is the data now; a drop that
    clipped ``ops`` would be silent otherwise.
    """
    _upgrade(_SEED_AT_REVISION, scratch_database)
    asyncio.run(_seed_representative_rows(scratch_database))

    _upgrade("head", scratch_database)

    present = {
        row["table_name"]
        for row in asyncio.run(
            _fetch(
                scratch_database,
                "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'",
            )
        )
    }

    assert present.isdisjoint(_MIRRORED_TABLES), (
        f"0034 left mirrored tables behind: {sorted(present & set(_MIRRORED_TABLES))}"
    )
    assert set(_SERVER_OWNED_TABLES) <= present, (
        f"0034 dropped server-owned tables: {sorted(set(_SERVER_OWNED_TABLES) - present)}"
    )

    # The publication went with the tables it replicated.
    publications = asyncio.run(
        _fetch(scratch_database, "SELECT pubname FROM pg_publication WHERE pubname = 'powersync'")
    )
    assert publications == []


def test_head_is_reached_twice_without_error(scratch_database: str) -> None:
    """ADR-0012's re-runnable contract across the drop itself.

    The release phase runs ``alembic upgrade head`` on every deploy, and a
    redeploy of the same build runs it against a database already at head.  A
    ``drop_table`` without ``if_exists`` would make the *second* pass the one
    that crash-loops, which is exactly the failure a green first deploy hides.
    """
    _upgrade("head", scratch_database)

    _upgrade("head", scratch_database)

    stamped = asyncio.run(_fetch(scratch_database, "SELECT version_num FROM alembic_version"))
    assert stamped == [{"version_num": _HEAD_REVISION}]


def test_downgrading_past_the_drop_refuses_loudly(scratch_database: str) -> None:
    """0034's downgrade must fail before touching schema, not recreate an empty mirror.

    Recreating fifteen empty tables would restore the shape of a cache and none
    of its contents.  The migration says so and raises; this pins that the raise
    is what an operator reaching for ``alembic downgrade`` actually gets, and
    that the stamp does not move.
    """
    _upgrade("head", scratch_database)

    result = _alembic("downgrade", _LAST_MIRRORED_REVISION, scratch_database)

    assert result.returncode != 0
    assert "irreversible" in result.stderr
    assert "alembic stamp" in result.stderr

    stamped = asyncio.run(_fetch(scratch_database, "SELECT version_num FROM alembic_version"))
    assert stamped == [{"version_num": _HEAD_REVISION}]
