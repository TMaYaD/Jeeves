"""The author-chain race, staged against a real Postgres.

``uq_ops_workspace_author_seq`` exists because ``POST /w/{w}/ops`` reads
``MAX(author_seq)`` and *then* inserts: two requests from one author can both
resolve the same maximum and both believe they own the next slot.  Every other
test in this suite runs on SQLite, which cannot stage that — a write behind a
stale read there is a lock error, not a constraint violation, so the handler's
recovery branch is unreachable.

Postgres checks a unique index against every committed row regardless of the
writer's snapshot, so a ``REPEATABLE READ`` transaction reproduces the
interleaving exactly: the losing session's reads are pinned to a snapshot from
before the winner committed, and its insert is refused by the database rather
than by the gap check.  That is the real thing, and what it must never be is a
500 — the tests below pin the two outcomes the handler is allowed to produce.

The endpoint is called as a plain coroutine rather than over HTTP because the
point is to control which session sees what, and the ASGI client owns its own.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator

import pytest
import pytest_asyncio
from fastapi import HTTPException
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.auth.models import User
from app.database import Base
from app.sync.ids import implicit_workspace_id
from app.sync.models import Member, Op
from app.sync.routes import post_ops
from app.sync.schemas import PostOpsRequest
from tests.sync.builders import SpecDevice, encode

asyncpg = pytest.importorskip("asyncpg")

# Created and dropped here.  Deliberately not the suite's own database: CI
# migrates that one and other tests share it.
_SCRATCH_DB = "jeeves_author_chain_race_test"

_USER_ID = "author-chain-race-user"


def _database_url() -> str:
    """The Postgres URL to build the scratch database beside, or skip.

    Read from the environment rather than ``app.config.settings``: settings
    supplies a localhost default when DATABASE_URL is unset, which would turn
    "no Postgres here" into a connection error instead of a skip.
    """
    url = os.environ.get("DATABASE_URL", "")
    if "postgres" not in url:
        if os.environ.get("CI"):
            # This module is the only coverage of the handler's constraint-race
            # recovery, so a silent skip in CI would retire it unnoticed.
            pytest.fail("DATABASE_URL must point at Postgres in CI — this test must not skip.")
        pytest.skip("requires a Postgres DATABASE_URL")
    return url


def _asyncpg_dsn(url: str, database: str) -> str:
    scheme, _, rest = url.partition("://")
    scheme = scheme.replace("+asyncpg", "")
    host_part = rest.rpartition("/")[0] or rest
    return f"{scheme}://{host_part}/{database}"


async def _admin_execute(dsn: str, statement: str) -> None:
    connection = await asyncpg.connect(dsn)
    try:
        await connection.execute(statement)
    finally:
        await connection.close()


@pytest_asyncio.fixture
async def race_engine() -> AsyncIterator[AsyncEngine]:
    """An empty scratch database with the ORM schema, dropped afterwards."""
    url = _database_url()
    admin_dsn = _asyncpg_dsn(url, "postgres")
    scratch_dsn = _asyncpg_dsn(url, _SCRATCH_DB)

    # CREATE/DROP DATABASE cannot run inside a transaction block.
    await _admin_execute(admin_dsn, f'DROP DATABASE IF EXISTS "{_SCRATCH_DB}" WITH (FORCE)')
    await _admin_execute(admin_dsn, f'CREATE DATABASE "{_SCRATCH_DB}"')

    engine = create_async_engine(scratch_dsn.replace("postgresql://", "postgresql+asyncpg://"))
    try:
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        yield engine
    finally:
        await engine.dispose()
        await _admin_execute(admin_dsn, f'DROP DATABASE IF EXISTS "{_SCRATCH_DB}" WITH (FORCE)')


@pytest_asyncio.fixture
async def enrolled(race_engine: AsyncEngine) -> tuple[User, SpecDevice]:
    """One user with one registered device, committed and visible to everyone."""
    user = User(id=_USER_ID, email="author-chain-race@example.com", hashed_password="x")
    device = SpecDevice()
    async with async_sessionmaker(race_engine, expire_on_commit=False)() as session:
        session.add(user)
        session.add(
            Member(
                member_id=device.member_id,
                user_id=user.id,
                sign_pk=device.sign_pk,
                key_id=device.key_id,
            )
        )
        await session.commit()
    return user, device


async def _pin_snapshot_before_the_winner(session: AsyncSession) -> None:
    """Fix this transaction's snapshot to the (empty) log as it is right now.

    ``REPEATABLE READ`` plus one read is what makes the interleaving
    deterministic: from here the session's ``MAX(author_seq)`` is frozen at the
    pre-winner value, exactly as a concurrent request's would be once it had
    read.
    """
    await session.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ"))
    assert (await session.execute(select(Op))).scalars().all() == []


async def test_a_raced_fork_of_the_author_chain_is_a_409_not_a_500(
    race_engine: AsyncEngine, enrolled: tuple[User, SpecDevice]
) -> None:
    """Two *different* ops in one slot: the loser gets the gap conflict.

    The database refuses the insert, the handler discards its stale read and
    resolves again against what is now committed — where the op is a genuine
    fork, so the answer is the same 409 a sequential gap earns.
    """
    user, device = enrolled
    workspace_id = implicit_workspace_id(user.id)
    winner = device.next_envelope(workspace_id, advance=False)
    loser = device.next_envelope(workspace_id, advance=False)
    assert winner != loser

    sessions = async_sessionmaker(race_engine, expire_on_commit=False)
    async with sessions() as losing, sessions() as winning:
        await _pin_snapshot_before_the_winner(losing)

        await post_ops(workspace_id, PostOpsRequest(ops=[encode(winner)]), winning, user)

        with pytest.raises(HTTPException) as refusal:
            await post_ops(workspace_id, PostOpsRequest(ops=[encode(loser)]), losing, user)
        assert refusal.value.status_code == 409

    async with sessions() as reader:
        stored = (await reader.execute(select(Op))).scalars().all()
    assert [op.envelope for op in stored] == [winner]


async def test_a_raced_replay_comes_back_as_the_idempotent_duplicate(
    race_engine: AsyncEngine, enrolled: tuple[User, SpecDevice]
) -> None:
    """The *same* op posted twice at once: the loser is told it already landed.

    This is the outcome that makes a client's retry safe. The second resolution
    finds the winner's row under the same ``(author, op_id)`` key and answers
    with its seq, so a device that retried a timed-out POST learns the op is
    held rather than that its chain is broken.
    """
    user, device = enrolled
    workspace_id = implicit_workspace_id(user.id)
    replayed = device.next_envelope(workspace_id)

    sessions = async_sessionmaker(race_engine, expire_on_commit=False)
    async with sessions() as losing, sessions() as winning:
        await _pin_snapshot_before_the_winner(losing)

        first = await post_ops(workspace_id, PostOpsRequest(ops=[encode(replayed)]), winning, user)
        assert [result.duplicate for result in first.results] == [False]

        second = await post_ops(workspace_id, PostOpsRequest(ops=[encode(replayed)]), losing, user)

    assert [result.duplicate for result in second.results] == [True]
    assert [result.seq for result in second.results] == [result.seq for result in first.results]

    async with sessions() as reader:
        stored = (await reader.execute(select(Op))).scalars().all()
    assert [op.envelope for op in stored] == [replayed]


async def test_the_constraint_is_scoped_to_one_author_in_one_workspace(
    race_engine: AsyncEngine, enrolled: tuple[User, SpecDevice]
) -> None:
    """Two authors filling *their own* slot 1 concurrently both succeed.

    A constraint that serialised unrelated authors would be a throughput bug
    dressed as a safety one.
    """
    user, device = enrolled
    workspace_id = implicit_workspace_id(user.id)
    second_device = SpecDevice()

    sessions = async_sessionmaker(race_engine, expire_on_commit=False)
    async with sessions() as setup:
        setup.add(
            Member(
                member_id=second_device.member_id,
                user_id=user.id,
                sign_pk=second_device.sign_pk,
                key_id=second_device.key_id,
            )
        )
        await setup.commit()

    from_first = device.next_envelope(workspace_id)
    from_second = second_device.next_envelope(workspace_id)

    async with sessions() as other, sessions() as one:
        await _pin_snapshot_before_the_winner(other)
        await post_ops(workspace_id, PostOpsRequest(ops=[encode(from_first)]), one, user)
        accepted = await post_ops(
            workspace_id, PostOpsRequest(ops=[encode(from_second)]), other, user
        )
    assert [result.duplicate for result in accepted.results] == [False]

    async with sessions() as reader:
        stored = (await reader.execute(select(Op).order_by(Op.seq))).scalars().all()
    assert {op.envelope for op in stored} == {from_first, from_second}
