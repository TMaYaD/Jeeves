"""Shared pytest fixtures for the test suite.

Uses an in-memory SQLite database (via aiosqlite) so tests require no
running Postgres instance.  A single engine is created once per session
(StaticPool keeps the one in-memory connection alive); each test runs
inside an outer transaction that is rolled back afterwards, so committed
rows never leak between tests.  The `get_db` dependency is overridden on
the FastAPI app for each test.
"""

import os
from collections.abc import AsyncIterator

import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import event
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    create_async_engine,
)
from sqlalchemy.pool import StaticPool

# Provide a dummy secret key for tests (before app code reads settings at import time).
os.environ.setdefault("SECRET_KEY", "test-secret-key")
# Lowest valid bcrypt work factor.  The real hashing code path still runs, but
# the suite's ~150 register() calls no longer dominate the run.  Production keeps
# the default 12 (see app.config.Settings.bcrypt_rounds).
os.environ.setdefault("BCRYPT_ROUNDS", "4")

from app.database import Base, get_db  # noqa: E402
from app.main import app  # noqa: E402

TEST_DATABASE_URL = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture(scope="session")
async def engine() -> AsyncIterator[AsyncEngine]:
    # One shared in-memory database for the whole session.  In-memory SQLite is
    # per-connection, so StaticPool pins a single underlying connection and the
    # schema created here stays visible to every test.  Per-test isolation is the
    # `db` fixture's job (outer transaction + rollback), not a fresh database.
    _engine = create_async_engine(
        TEST_DATABASE_URL,
        echo=False,
        poolclass=StaticPool,
        connect_args={"check_same_thread": False},
    )

    # pysqlite/aiosqlite's legacy transaction control does not begin real
    # transactions, which breaks SAVEPOINT and lets committed rows survive a
    # rollback — the per-test `db` isolation depends on both working.  Disable
    # the driver's implicit BEGIN and emit it ourselves (SQLAlchemy's documented
    # pysqlite recipe).
    @event.listens_for(_engine.sync_engine, "connect")
    def _sqlite_disable_autobegin(dbapi_connection: object, _record: object) -> None:
        dbapi_connection.isolation_level = None  # type: ignore[attr-defined]

    @event.listens_for(_engine.sync_engine, "begin")
    def _sqlite_emit_begin(conn: object) -> None:
        conn.exec_driver_sql("BEGIN")  # type: ignore[attr-defined]

    async with _engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield _engine
    await _engine.dispose()


@pytest_asyncio.fixture
async def db(engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    # Wrap each test in an outer transaction that is always rolled back, so
    # committed rows never leak between tests despite the shared engine.  The
    # session joins that transaction through a SAVEPOINT (join_transaction_mode),
    # so route-level commits persist within the test but vanish on rollback.
    connection = await engine.connect()
    trans = await connection.begin()
    session = AsyncSession(
        bind=connection,
        expire_on_commit=False,
        join_transaction_mode="create_savepoint",
    )
    try:
        yield session
    finally:
        await session.close()
        await trans.rollback()
        await connection.close()


@pytest_asyncio.fixture
async def client(db: AsyncSession) -> AsyncIterator[AsyncClient]:
    async def override_get_db() -> AsyncIterator[AsyncSession]:
        yield db

    app.dependency_overrides[get_db] = override_get_db
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()


async def register(client: AsyncClient, email: str, password: str = "secret") -> str:
    """Register a user and return the access token."""
    reg = await client.post("/user", json={"email": email, "password": password})
    token: str = reg.json()["access_token"]
    return token


async def register_full(
    client: AsyncClient, email: str, password: str = "secret"
) -> tuple[str, str]:
    """Register a user and return (access_token, refresh_token)."""
    reg = await client.post("/user", json={"email": email, "password": password})
    assert reg.status_code == 201, f"register failed: {reg.status_code} {reg.text}"
    data = reg.json()
    return data["access_token"], data["refresh_token"]


def auth_header(token: str) -> dict[str, str]:
    """Return an Authorization header dict for the given token."""
    return {"Authorization": f"Bearer {token}"}
