"""The constraint races, staged against a real Postgres.

Two of them, and both are the same shape: the handler reads, decides, and *then*
writes, so a concurrent request can invalidate the read before the write lands.

``uq_ops_workspace_author_seq`` exists because ``POST /w/{w}/ops`` reads
``MAX(author_seq)`` and *then* inserts: two requests from one author can both
resolve the same maximum and both believe they own the next slot.  The
``workspaces`` primary key is the other: genesis authorship is
log-state-conditioned, so ``_verify_genesis`` reads whether the Workspace exists
and two Root-holding devices can both be told no.  Every other test in this suite
runs on SQLite, which cannot stage either — a write behind a stale read there is a
lock error, not a constraint violation, so the handler's recovery branches are
unreachable.

Postgres checks a unique index against every committed row regardless of the
writer's snapshot, so a ``REPEATABLE READ`` transaction reproduces the
interleaving exactly: the losing session's reads are pinned to a snapshot from
before the winner committed, and its insert is refused by the database rather
than by the gap check.  That is the real thing, and what it must never be is a
500 — the tests below pin the two outcomes the handler is allowed to produce.

The endpoint is called as a plain coroutine rather than over HTTP because the
point is to control which session sees what, and the ASGI client owns its own.
A direct call resolves no ``Depends``, so **every** dependency is supplied by
hand — the session, the authenticated Member and the signal hub alike.  The hub
is a real one, subscribed to: the post-commit poke is part of what the recovery
branch has to get right, and this is the only place a *raced* replay (all
duplicates, so no news) is exercised at all.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime

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
from app.sync.control_payload import GRANTER_ROOT, MEMBER_KIND_DEVICE, ROLE_OWNER
from app.sync.ids import default_workspace_id
from app.sync.models import Grant, Member, Op, RecoveryEscrow, Workspace
from app.sync.routes import post_ops
from app.sync.schemas import PostOpsRequest
from app.sync.signal_hub import SignalHub
from tests.sync.builders import SpecDevice, SpecRoot, encode, escrow_blob

asyncpg = pytest.importorskip("asyncpg")

# Created and dropped here.  Deliberately not the suite's own database: CI
# migrates that one and other tests share it.
_SCRATCH_DB = "jeeves_author_chain_race_test"

_USER_ID = "author-chain-race-user"

#: A second account, so the genesis race starts from an *unfounded* Workspace —
#: the ``enrolled`` fixture seeds one on purpose and cannot be reused for it.
_GENESIS_USER_ID = "genesis-race-user"


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


def _asyncpg_dsn(url: str, database: str, *, driver: str = "") -> str:
    """Rewrite [url] to name [database], normalising the scheme on the way.

    ``_database_url`` admits any URL containing ``postgres``, and ``postgres://``
    is the common spelling — but SQLAlchemy has no dialect under that name, so
    leaving it alone means the scratch engine dies in fixture setup instead of the
    run skipping cleanly.  Normalising here rather than at each call site is what
    keeps both consumers agreeing on one spelling.

    [driver] appends SQLAlchemy's dialect driver (``asyncpg``); the bare form is
    what ``asyncpg.connect`` itself wants.  Naming it beats rewriting the scheme
    again at the call site, where a normalisation slip would silently miss.
    """
    scheme, _, rest = url.partition("://")
    scheme = scheme.replace("+asyncpg", "")
    if scheme == "postgres":
        scheme = "postgresql"
    if driver:
        scheme = f"{scheme}+{driver}"
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

    # CREATE/DROP DATABASE cannot run inside a transaction block.
    await _admin_execute(admin_dsn, f'DROP DATABASE IF EXISTS "{_SCRATCH_DB}" WITH (FORCE)')
    await _admin_execute(admin_dsn, f'CREATE DATABASE "{_SCRATCH_DB}"')

    engine = create_async_engine(_asyncpg_dsn(url, _SCRATCH_DB, driver="asyncpg"))
    try:
        async with engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        yield engine
    finally:
        await engine.dispose()
        await _admin_execute(admin_dsn, f'DROP DATABASE IF EXISTS "{_SCRATCH_DB}" WITH (FORCE)')


@pytest_asyncio.fixture
async def enrolled(race_engine: AsyncEngine) -> tuple[User, Member, SpecDevice]:
    """One user with one registered device in a founded Workspace, committed.

    The endpoint authenticates the *Member*, so the fixture hands back the row the
    member-scoped token would have resolved to.  The ``workspaces`` and ``grants``
    rows are seeded directly rather than through a genesis batch: they are the
    server's own materialised index (ADR-0028), and what this file races is the
    author-chain constraint, not the control plane that fills them.  Without them
    a content POST would be refused before the race could happen.
    """
    user = User(id=_USER_ID, email="author-chain-race@example.com", hashed_password="x")
    device = SpecDevice()
    member = Member(
        member_id=device.member_id,
        user_id=user.id,
        sign_pk=device.sign_pk,
        key_id=device.key_id,
        kex_pk=device.kex_pk,
        member_kind=MEMBER_KIND_DEVICE,
        chained_at=datetime.now(UTC),
    )
    async with async_sessionmaker(race_engine, expire_on_commit=False)() as session:
        session.add(user)
        session.add(member)
        session.add(Workspace(workspace_id=default_workspace_id(user.id), genesis_seq=0))
        session.add(
            Grant(
                workspace_id=default_workspace_id(user.id),
                grant_id=uuid.uuid4(),
                member_id=device.member_id,
                role=ROLE_OWNER,
                granter=GRANTER_ROOT,
                granted_seq=0,
            )
        )
        await session.commit()
    return user, member, device


@pytest_asyncio.fixture
async def unfounded(race_engine: AsyncEngine) -> tuple[User, Member, SpecDevice, SpecRoot]:
    """Two registered devices, one escrowed Root, and **no Workspace row**.

    The state the genesis race starts from: both devices hold Root (here, the one
    ``SpecRoot`` whose public half is in the escrow slot the server checks against)
    and neither Workspace exists yet, so both are entitled to found it.

    Only one ``Member`` is returned because the endpoint authenticates one at a
    time; the second device's row is committed alongside it and its Member is
    rebuilt by the test that needs it.
    """
    user = User(id=_GENESIS_USER_ID, email="genesis-race@example.com", hashed_password="x")
    device = SpecDevice()
    root = SpecRoot()
    workspace_id = default_workspace_id(user.id)
    member = Member(
        member_id=device.member_id,
        user_id=user.id,
        sign_pk=device.sign_pk,
        key_id=device.key_id,
        kex_pk=device.kex_pk,
        member_kind=MEMBER_KIND_DEVICE,
    )
    async with async_sessionmaker(race_engine, expire_on_commit=False)() as session:
        session.add(user)
        session.add(member)
        # The escrow slot is what resolves ``root_pk`` for this Workspace, so
        # without it nothing can be Root-signed and the race never gets far enough
        # to be one.
        session.add(
            RecoveryEscrow(
                workspace_id=workspace_id,
                user_id=user.id,
                version=1,
                blob=escrow_blob(),
                root_pk=root.root_pk,
                root_sig=b"\x00" * 64,
            )
        )
        await session.commit()
    return user, member, device, root


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
    race_engine: AsyncEngine, enrolled: tuple[User, Member, SpecDevice]
) -> None:
    """Two *different* ops in one slot: the loser gets the gap conflict.

    The database refuses the insert, the handler discards its stale read and
    resolves again against what is now committed — where the op is a genuine
    fork, so the answer is the same 409 a sequential gap earns.
    """
    user, member, device = enrolled
    workspace_id = default_workspace_id(user.id)
    winner = device.next_envelope(workspace_id, advance=False)
    loser = device.next_envelope(workspace_id, advance=False)
    assert winner != loser

    hub = SignalHub()
    sessions = async_sessionmaker(race_engine, expire_on_commit=False)
    with hub.subscribe(workspace_id, member.member_id) as subscriber:
        async with sessions() as losing, sessions() as winning:
            await _pin_snapshot_before_the_winner(losing)

            await post_ops(workspace_id, PostOpsRequest(ops=[encode(winner)]), winning, member, hub)
            assert subscriber.pending()
            subscriber.clear()

            with pytest.raises(HTTPException) as refusal:
                await post_ops(
                    workspace_id, PostOpsRequest(ops=[encode(loser)]), losing, member, hub
                )
            assert refusal.value.status_code == 409
            # The *full* gap verdict, which is the whole point of the retry: it
            # resolved against committed state, so ``expected_author_seq`` is a
            # read rather than a guess, and the loser learns it sent a position
            # the winner now holds.  The bare ``{"code": ...}`` belongs to the
            # one case that resolves nothing — a retry that loses the constraint
            # a second time — and this interleaving cannot stage it.
            # ``HTTPException.detail`` is annotated ``str`` upstream while the
            # routes raise structured objects through it, so the comparison is
            # widened here rather than the assertion weakened to a substring
            # match.
            detail: object = refusal.value.detail
            assert detail == {
                "code": "author_chain_conflict",
                "index": 0,
                "author_seq": 1,
                "expected_author_seq": 2,
            }
        # A batch that stored nothing is not news, however it was refused.
        assert not subscriber.pending()

    async with sessions() as reader:
        stored = (await reader.execute(select(Op))).scalars().all()
    assert [op.envelope for op in stored] == [winner]


async def test_a_raced_replay_comes_back_as_the_idempotent_duplicate(
    race_engine: AsyncEngine, enrolled: tuple[User, Member, SpecDevice]
) -> None:
    """The *same* op posted twice at once: the loser is told it already landed.

    This is the outcome that makes a client's retry safe. The second resolution
    finds the winner's row under the same ``(author, op_id)`` key and answers
    with its seq, so a device that retried a timed-out POST learns the op is
    held rather than that its chain is broken.
    """
    user, member, device = enrolled
    workspace_id = default_workspace_id(user.id)
    replayed = device.next_envelope(workspace_id)

    hub = SignalHub()
    sessions = async_sessionmaker(race_engine, expire_on_commit=False)
    with hub.subscribe(workspace_id, member.member_id) as subscriber:
        async with sessions() as losing, sessions() as winning:
            await _pin_snapshot_before_the_winner(losing)

            first = await post_ops(
                workspace_id, PostOpsRequest(ops=[encode(replayed)]), winning, member, hub
            )
            assert [result.duplicate for result in first.results] == [False]
            assert subscriber.pending()
            subscriber.clear()

            second = await post_ops(
                workspace_id, PostOpsRequest(ops=[encode(replayed)]), losing, member, hub
            )
        # The second resolution found the winner's row: a replay, not news.
        assert not subscriber.pending()

    assert [result.duplicate for result in second.results] == [True]
    assert [result.seq for result in second.results] == [result.seq for result in first.results]

    async with sessions() as reader:
        stored = (await reader.execute(select(Op))).scalars().all()
    assert [op.envelope for op in stored] == [replayed]


async def test_the_constraint_is_scoped_to_one_author_in_one_workspace(
    race_engine: AsyncEngine, enrolled: tuple[User, Member, SpecDevice]
) -> None:
    """Two authors filling *their own* slot 1 concurrently both succeed.

    A constraint that serialised unrelated authors would be a throughput bug
    dressed as a safety one.
    """
    user, member, device = enrolled
    workspace_id = default_workspace_id(user.id)
    second_device = SpecDevice()

    second_member = Member(
        member_id=second_device.member_id,
        user_id=user.id,
        sign_pk=second_device.sign_pk,
        key_id=second_device.key_id,
        kex_pk=second_device.kex_pk,
        member_kind=MEMBER_KIND_DEVICE,
        chained_at=datetime.now(UTC),
    )
    sessions = async_sessionmaker(race_engine, expire_on_commit=False)
    async with sessions() as setup:
        setup.add(second_member)
        # Its own live Grant, seeded the same way the fixture seeds the founder's:
        # a content POST needs one, and what this races is the chain constraint.
        setup.add(
            Grant(
                workspace_id=workspace_id,
                grant_id=uuid.uuid4(),
                member_id=second_device.member_id,
                role=ROLE_OWNER,
                granter=GRANTER_ROOT,
                granted_seq=0,
            )
        )
        await setup.commit()

    from_first = device.next_envelope(workspace_id)
    from_second = second_device.next_envelope(workspace_id)

    hub = SignalHub()
    with hub.subscribe(workspace_id, member.member_id) as subscriber:
        async with sessions() as other, sessions() as one:
            await _pin_snapshot_before_the_winner(other)
            await post_ops(workspace_id, PostOpsRequest(ops=[encode(from_first)]), one, member, hub)
            assert subscriber.pending()
            subscriber.clear()

            accepted = await post_ops(
                workspace_id,
                PostOpsRequest(ops=[encode(from_second)]),
                other,
                second_member,
                hub,
            )
        # Both authors stored an op, so both appends are news.
        assert subscriber.pending()
    assert [result.duplicate for result in accepted.results] == [False]

    async with sessions() as reader:
        stored = (await reader.execute(select(Op).order_by(Op.seq))).scalars().all()
    assert {op.envelope for op in stored} == {from_first, from_second}


async def test_a_truly_concurrent_second_genesis_is_a_409_not_a_500(
    race_engine: AsyncEngine, unfounded: tuple[User, Member, SpecDevice, SpecRoot]
) -> None:
    """Both devices are told the Workspace does not exist.  One of them is wrong.

    ``_verify_genesis`` refuses a second genesis by reading the ``workspaces``
    row — a read, and therefore snapshot-bound.  Under a real interleave the loser
    passes that check, appends its ops, materialises a ``Workspace`` whose primary
    key the winner already committed, and only finds out at ``COMMIT``.  That is
    *outside* the retried append block, so before this branch existed it escaped as
    an unhandled ``IntegrityError`` and the loser got a 500.

    A 500 is the wrong answer twice over: it says nothing about what to do next,
    and what to do next is well defined and already implemented — drop the queued
    genesis, pull the winner's, and claim a place with a ``member_register``.  So
    the loser gets the same deterministic ``genesis_not_first`` the sequential case
    gives it, and the ops it appended roll back with the commit that lost.
    """
    user, member, device, root = unfounded
    workspace_id = default_workspace_id(user.id)
    rival = SpecDevice()
    sessions = async_sessionmaker(race_engine, expire_on_commit=False)
    async with sessions() as setup:
        setup.add(
            Member(
                member_id=rival.member_id,
                user_id=user.id,
                sign_pk=rival.sign_pk,
                key_id=rival.key_id,
                kex_pk=rival.kex_pk,
                member_kind=MEMBER_KIND_DEVICE,
            )
        )
        await setup.commit()
        rival_member = await setup.get(Member, rival.member_id)
        assert rival_member is not None

    winner = root.genesis_envelope(device, workspace_id)
    loser = root.genesis_envelope(rival, workspace_id)

    hub = SignalHub()
    async with sessions() as losing, sessions() as winning:
        # The losing session's snapshot is pinned before the winner commits, so its
        # ``workspaces`` read comes back empty exactly as a concurrent request's
        # would once it had read.
        await _pin_snapshot_before_the_winner(losing)

        founded = await post_ops(
            workspace_id, PostOpsRequest(ops=[encode(winner)]), winning, member, hub
        )
        assert [result.duplicate for result in founded.results] == [False]

        with pytest.raises(HTTPException) as refusal:
            await post_ops(
                workspace_id, PostOpsRequest(ops=[encode(loser)]), losing, rival_member, hub
            )
    assert refusal.value.status_code == 409
    detail: object = refusal.value.detail
    assert detail == {"code": "genesis_not_first", "index": 0}

    # Exactly one genesis and one Workspace row, with nothing of the loser's left
    # behind — the append rolled back with the commit that lost it.
    async with sessions() as reader:
        stored = (await reader.execute(select(Op).order_by(Op.seq))).scalars().all()
        workspaces = (await reader.execute(select(Workspace))).scalars().all()
    assert [op.envelope for op in stored] == [winner]
    assert [row.workspace_id for row in workspaces] == [workspace_id]
