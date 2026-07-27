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

_OUTCOME_WITH_CURSOR = "chain-todo-with-cursor"
_OUTCOME_WITHOUT_CLARIFIED_AT = "chain-todo-fallback"
_OUTCOME_BLANK_CURSOR = "chain-todo-blank-cursor"
_OUTCOME_NULL_CURSOR = "chain-todo-null-cursor"

# uuid5(NAMESPACE_URL, "jeeves://action/backfill/<todo_id>") — the deterministic
# ids 0028 mints.  Spelled out rather than recomputed with the migration's own
# helper so a change to that helper fails this test instead of moving with it.
_BACKFILL_IDS = {
    _OUTCOME_WITH_CURSOR: "9565a928-0420-5407-bbc5-cf40a43c8a29",
    _OUTCOME_WITHOUT_CLARIFIED_AT: "5572bb54-7f88-5cf9-b8a1-39b30dc21adc",
}


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


def _downgrade(revision: str, scratch_dsn: str) -> None:
    result = _alembic("downgrade", revision, scratch_dsn)
    assert result.returncode == 0, (
        f"alembic downgrade {revision} failed\n"
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
            "        'Email Bob about the contract', 'high', 30, now())",
            _OUTCOME_WITH_CURSOR,
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
    assert stamped == [{"version_num": "0030"}]


def test_backfill_mints_one_current_action_per_non_blank_cursor(
    scratch_database: str,
) -> None:
    """0028's backfill, verified on the rows Postgres actually stored."""
    _upgrade(_SEED_AT_REVISION, scratch_database)
    asyncio.run(_seed_representative_rows(scratch_database))
    _upgrade("head", scratch_database)

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
    assert with_cursor["text"] == "Email Bob about the contract"
    assert with_cursor["energy_level"] == "high"
    assert with_cursor["time_estimate"] == 30
    assert with_cursor["user_id"] == "chain-user"


def test_rerunning_upgrade_head_is_a_no_op(scratch_database: str) -> None:
    """ADR-0012's re-runnable contract, exercised against real Postgres.

    A second ``upgrade head`` must neither fail nor duplicate backfilled rows —
    the guard 0028 relies on for drift recovery and for runs that land after
    clients have already uploaded their own backfill Actions (ADR-0019).
    """
    _upgrade(_SEED_AT_REVISION, scratch_database)
    asyncio.run(_seed_representative_rows(scratch_database))
    _upgrade("head", scratch_database)

    _upgrade("head", scratch_database)

    actions = asyncio.run(_fetch(scratch_database, "SELECT id FROM actions"))
    assert len(actions) == len(_BACKFILL_IDS)


def test_0028_backfill_reapplied_over_existing_rows_is_a_no_op(
    scratch_database: str,
) -> None:
    """0028 re-run *while its rows already exist* — the guard's real job.

    ``upgrade head`` from head is a no-op because Alembic skips applied
    revisions, so it never re-enters the backfill.  Driving 0028 down to 0029
    and back up does: the downgrade of 0029 leaves ``actions`` and its rows in
    place (0028 is irreversible by design and refuses to drop them), so the
    second forward run re-executes the backfill against a table that already
    holds every row it is about to insert.
    """
    _upgrade(_SEED_AT_REVISION, scratch_database)
    asyncio.run(_seed_representative_rows(scratch_database))
    _upgrade("head", scratch_database)

    # A row a client uploaded after the first backfill must survive untouched.
    asyncio.run(
        _execute(
            scratch_database,
            [
                "UPDATE actions SET text = 'edited by a client' "
                f"WHERE outcome_id = '{_OUTCOME_WITH_CURSOR}'"
            ],
        )
    )

    _downgrade("0028", scratch_database)
    _upgrade("head", scratch_database)

    actions = asyncio.run(
        _fetch(scratch_database, "SELECT outcome_id, text FROM actions ORDER BY outcome_id")
    )
    assert len(actions) == len(_BACKFILL_IDS)
    # DO NOTHING, not DO UPDATE: the client's edit is not clobbered by a re-run.
    assert actions[1]["text"] == "edited by a client"
