"""Integration tests for the SWS auth routes (POST /auth/sws/challenge and POST /auth/sws)."""

import base64
import os

import fakeredis.aioredis
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from nacl.signing import SigningKey
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

os.environ.setdefault("SECRET_KEY", "test-secret-key")

from app.auth.providers.sws_strategy import SIWS_TEMPLATE
from app.database import Base, get_db
from app.main import app
from app.redis import get_redis

TEST_DB_URL = "sqlite+aiosqlite:///:memory:"


@pytest_asyncio.fixture
async def engine():
    _engine = create_async_engine(TEST_DB_URL, echo=False)
    async with _engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield _engine
    await _engine.dispose()


@pytest_asyncio.fixture
async def db(engine):
    factory = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
    async with factory() as session:
        yield session
        await session.rollback()


@pytest_asyncio.fixture
async def fake_redis():
    return fakeredis.aioredis.FakeRedis(decode_responses=True)


@pytest_asyncio.fixture
async def client(db, fake_redis):
    async def override_get_db():
        yield db

    async def override_get_redis():
        yield fake_redis

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_redis] = override_get_redis
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c
    app.dependency_overrides.clear()


@pytest.fixture
def signing_key():
    return SigningKey.generate()


def _b58encode(data: bytes) -> str:
    import base58 as _base58

    return _base58.b58encode(data).decode()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_sws_challenge_returns_nonce(client, signing_key):
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    response = await client.post("/auth/sws/challenge", json={"public_key": public_key_b58})
    assert response.status_code == 200
    data = response.json()
    assert data["nonce"]
    assert data["issued_at"]
    assert data["domain"] == "jeeves.app"


@pytest.mark.asyncio
async def test_sws_login_happy_path(client, signing_key):
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))

    # Step 1: get challenge.
    challenge = await client.post("/auth/sws/challenge", json={"public_key": public_key_b58})
    assert challenge.status_code == 200
    nonce = challenge.json()["nonce"]
    issued_at = challenge.json()["issued_at"]

    # Step 2: sign the SIWS message.
    message = SIWS_TEMPLATE.format(
        domain="jeeves.app",
        public_key=public_key_b58,
        nonce=nonce,
        issued_at=issued_at,
    ).encode()
    signed = signing_key.sign(message)
    signature_b64 = base64.b64encode(signed.signature).decode()

    # Step 3: login.
    response = await client.post(
        "/auth/sws",
        json={
            "public_key": public_key_b58,
            "signature": signature_b64,
            "nonce": nonce,
        },
    )
    assert response.status_code == 200
    data = response.json()
    assert data["access_token"]
    assert data["refresh_token"]
    assert data["token_type"] == "bearer"


@pytest.mark.asyncio
async def test_sws_login_bad_signature_returns_401(client, signing_key):
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))

    challenge = await client.post("/auth/sws/challenge", json={"public_key": public_key_b58})
    nonce = challenge.json()["nonce"]
    bad_sig = base64.b64encode(b"\x00" * 64).decode()

    response = await client.post(
        "/auth/sws",
        json={
            "public_key": public_key_b58,
            "signature": bad_sig,
            "nonce": nonce,
        },
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_sws_login_missing_nonce_returns_401(client, signing_key):
    public_key_b58 = _b58encode(bytes(signing_key.verify_key))
    bad_sig = base64.b64encode(b"\x00" * 64).decode()

    response = await client.post(
        "/auth/sws",
        json={
            "public_key": public_key_b58,
            "signature": bad_sig,
            "nonce": "totally-made-up-nonce",
        },
    )
    assert response.status_code == 401
