"""The realtime signal contract: `WS /w/{w}/signal`.

`app/test/sync/fake_sync_server_contract_test.dart` mirrors the cases that the
in-process fake can express, under the same names.  Four cases have no twin —
bad token, user-token-refused, missing auth frame, keepalive — because the fake
has no token model and no wall clock; they are backend-only by construction, and
the fake's `emittedSignalFrames` check is a fidelity smoke test rather than the
wire assertion.  **The load-bearing no-payload assertion lives here**: every poke
is a zero-length *text* frame, every keepalive is exactly ``KEEPALIVE_FRAME``,
and the socket never sends anything else.

The socket authenticates with a **member-scoped** credential, the same one the
ops routes require, so every session here runs the full enrolment ceremony
rather than stopping at ``POST /members``.  That is the point of
:func:`test_a_user_token_is_refused_with_4401`: a socket that accepted a plain
user session would be the weak door into a Workspace whose HTTP surface refuses
one.

Two harness constraints shape this module.  The WebSocket client's transport
owns an anyio task group, and pytest-asyncio runs fixture setup and teardown in
different tasks — so the client is opened inside the test body (via
:func:`subscribe`) rather than yielded from a fixture.  And every request here
shares the one transaction-bound session the ``db`` fixture provides, which
tolerates no concurrent use: a test must consume the handshake poke before it
issues an HTTP request, which is why :func:`subscribe` waits for it.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import AsyncIterator, Iterator
from contextlib import asynccontextmanager

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient, Response
from httpx_ws import AsyncWebSocketSession, WebSocketDisconnect, aconnect_ws
from httpx_ws.transport import ASGIWebSocketTransport
from redis.asyncio import Redis
from sqlalchemy.ext.asyncio import AsyncSession
from wsproto.events import BytesMessage, TextMessage

from app.config import settings
from app.database import get_db
from app.main import app
from app.redis import get_redis
from app.sync.routes import (
    KEEPALIVE_FRAME,
    SIGNAL_CLOSE_FORBIDDEN,
    SIGNAL_CLOSE_PROTOCOL_ERROR,
    SIGNAL_CLOSE_UNAUTHENTICATED,
)
from app.sync.signal_hub import SignalHub, get_signal_hub
from tests.sync.builders import Session, encode_all, open_session

#: Long enough that a healthy socket never emits one mid-test, so a keepalive
#: only ever shows up where a test asked for it by shortening the interval.
IDLE_TEST_INTERVAL_SECONDS = 30.0

#: What a test overrides the interval to when it *does* want a keepalive.  This
#: is the whole point of the interval being a Settings field.
FAST_TEST_INTERVAL_SECONDS = 0.05

#: How long a test waits for a frame that should already be in flight.
FRAME_TIMEOUT_SECONDS = 2.0

#: How long a test waits before concluding no frame is coming.  Every path that
#: would produce one is in-process, so this is generous.
SILENCE_WINDOW_SECONDS = 0.2


@pytest.fixture(autouse=True)
def slow_keepalive() -> Iterator[None]:
    """Park the keepalive out of the way unless a test explicitly wants one."""
    original = settings.signal_keepalive_interval_seconds
    settings.signal_keepalive_interval_seconds = IDLE_TEST_INTERVAL_SECONDS
    yield
    settings.signal_keepalive_interval_seconds = original


@pytest.fixture
def hub() -> SignalHub:
    return SignalHub()


@pytest_asyncio.fixture
async def http_client(db: AsyncSession, redis: Redis, hub: SignalHub) -> AsyncIterator[AsyncClient]:
    """The writer side: plain HTTP over the app, on the test's transaction.

    Installing the overrides here is what also binds the sockets opened by
    :func:`subscribe` to this same session and this same hub.  Redis is here
    because the enrolment ceremony every session now runs goes through the
    proof-of-possession challenge, which stores its nonce there.
    """

    async def override_get_db() -> AsyncIterator[AsyncSession]:
        yield db

    async def override_get_redis() -> AsyncIterator[Redis]:
        yield redis

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_redis] = override_get_redis
    app.dependency_overrides[get_signal_hub] = lambda: hub
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        yield client
    app.dependency_overrides.clear()


@pytest_asyncio.fixture
async def session(http_client: AsyncClient) -> Session:
    return await open_session(http_client, "signal-owner@example.com")


@asynccontextmanager
async def subscribe(
    workspace_id: uuid.UUID,
    token: str | None,
    *,
    expect_initial_poke: bool = True,
) -> AsyncIterator[AsyncWebSocketSession]:
    """Open a signal socket and send ``token`` as its first frame.

    ``token=None`` sends nothing, which is the protocol violation the auth
    deadline exists to catch.
    """
    ws: AsyncWebSocketSession
    async with (
        AsyncClient(transport=ASGIWebSocketTransport(app=app), base_url="http://test") as ws_client,
        aconnect_ws(f"http://test/w/{workspace_id}/signal", ws_client) as ws,
    ):
        if token is not None:
            await ws.send_text(token)
        if expect_initial_poke:
            await expect_poke(ws)
        yield ws


async def expect_poke(ws: AsyncWebSocketSession) -> None:
    """Assert the next frame is a poke: text, and completely empty."""
    event = await ws.receive(timeout=FRAME_TIMEOUT_SECONDS)
    assert isinstance(event, TextMessage), f"a poke must be a text frame, got {event!r}"
    assert event.data == "", f"a poke carries no payload, got {event.data!r}"


async def expect_silence(ws: AsyncWebSocketSession) -> None:
    with pytest.raises(TimeoutError):
        await ws.receive(timeout=SILENCE_WINDOW_SECONDS)


# --- Handshake ---------------------------------------------------------------


async def test_subscribe_acks_with_an_immediate_poke(
    http_client: AsyncClient, session: Session
) -> None:
    # The initial poke is the auth ack *and* the catch-up trigger: it is why the
    # server needs no memory of what any subscriber has already seen.
    async with subscribe(session.workspace_id, session.member_token):
        pass


async def test_subscribe_to_another_workspace_is_refused_with_4403(
    http_client: AsyncClient, session: Session
) -> None:
    async with subscribe(uuid.uuid4(), session.member_token, expect_initial_poke=False) as ws:
        with pytest.raises(WebSocketDisconnect) as refusal:
            await ws.receive(timeout=FRAME_TIMEOUT_SECONDS)
    assert refusal.value.code == SIGNAL_CLOSE_FORBIDDEN


async def test_a_bad_token_is_refused_with_4401(http_client: AsyncClient, session: Session) -> None:
    async with subscribe(session.workspace_id, "not-a-jwt", expect_initial_poke=False) as ws:
        with pytest.raises(WebSocketDisconnect) as refusal:
            await ws.receive(timeout=FRAME_TIMEOUT_SECONDS)
    assert refusal.value.code == SIGNAL_CLOSE_UNAUTHENTICATED


async def test_a_user_token_is_refused_with_4401(
    http_client: AsyncClient, session: Session
) -> None:
    """The socket is not the weak door.

    It resolves identity through the same ``resolve_member_token`` the ops routes
    use, so a valid *user* session — which cannot post or pull ops — cannot
    subscribe to news about the Workspace either.  Were this the one surface that
    still took a user token, a stolen session would learn every time the account
    was active, which is exactly the metadata the payload-free poke exists to
    avoid leaking.
    """
    async with subscribe(session.workspace_id, session.user_token, expect_initial_poke=False) as ws:
        with pytest.raises(WebSocketDisconnect) as refusal:
            await ws.receive(timeout=FRAME_TIMEOUT_SECONDS)
    assert refusal.value.code == SIGNAL_CLOSE_UNAUTHENTICATED


async def test_no_auth_frame_before_the_deadline_is_refused_with_4400(
    http_client: AsyncClient, session: Session
) -> None:
    # Runs in milliseconds: the deadline is a Settings field precisely so this
    # case never waits out the production value.
    original = settings.signal_auth_frame_deadline_seconds
    settings.signal_auth_frame_deadline_seconds = FAST_TEST_INTERVAL_SECONDS
    try:
        async with subscribe(session.workspace_id, None, expect_initial_poke=False) as ws:
            with pytest.raises(WebSocketDisconnect) as refusal:
                await ws.receive(timeout=FRAME_TIMEOUT_SECONDS)
    finally:
        settings.signal_auth_frame_deadline_seconds = original
    assert refusal.value.code == SIGNAL_CLOSE_PROTOCOL_ERROR


# --- Pokes -------------------------------------------------------------------


async def test_an_append_pokes_the_subscriber(http_client: AsyncClient, session: Session) -> None:
    async with subscribe(session.workspace_id, session.member_token) as ws:
        response = await http_client.post(
            f"/w/{session.workspace_id}/ops",
            json=encode_all(session.device.next_envelope(session.workspace_id)),
            headers=session.headers,
        )
        assert response.status_code == 200, response.text

        await expect_poke(ws)


async def test_a_duplicate_only_replay_does_not_poke(
    http_client: AsyncClient, session: Session
) -> None:
    envelope = session.device.next_envelope(session.workspace_id)
    first = await http_client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=session.headers,
    )
    assert first.status_code == 200, first.text

    async with subscribe(session.workspace_id, session.member_token) as ws:
        replay = await http_client.post(
            f"/w/{session.workspace_id}/ops",
            json=encode_all(envelope),
            headers=session.headers,
        )
        assert [r["duplicate"] for r in replay.json()["results"]] == [True]

        # Nothing was appended, so there is no news — a replay is not activity.
        await expect_silence(ws)


async def test_an_append_never_pokes_another_workspace(
    http_client: AsyncClient, session: Session
) -> None:
    neighbour = await open_session(http_client, "signal-neighbour@example.com")

    async with subscribe(neighbour.workspace_id, neighbour.member_token) as ws:
        response = await http_client.post(
            f"/w/{session.workspace_id}/ops",
            json=encode_all(session.device.next_envelope(session.workspace_id)),
            headers=session.headers,
        )
        assert response.status_code == 200, response.text

        await expect_silence(ws)


# --- Keepalive and the no-payload property -----------------------------------


async def test_an_idle_socket_emits_the_keepalive_literal(
    http_client: AsyncClient, session: Session
) -> None:
    settings.signal_keepalive_interval_seconds = FAST_TEST_INTERVAL_SECONDS
    async with subscribe(session.workspace_id, session.member_token) as ws:
        event = await ws.receive(timeout=FRAME_TIMEOUT_SECONDS)
        assert isinstance(event, TextMessage)
        assert event.data == KEEPALIVE_FRAME


async def test_the_socket_sends_only_empty_pokes_and_the_keepalive_literal(
    http_client: AsyncClient, session: Session
) -> None:
    """The load-bearing no-payload assertion.

    Over a session covering all three sources of traffic — the handshake ack, an
    append, and an idle stretch — every frame is text and is either empty or
    exactly the keepalive literal.  No other frame kind is ever produced.
    """
    settings.signal_keepalive_interval_seconds = FAST_TEST_INTERVAL_SECONDS
    frames: list[str] = []
    async with subscribe(
        session.workspace_id, session.member_token, expect_initial_poke=False
    ) as ws:
        frames.append(await _next_text_frame(ws))

        response = await http_client.post(
            f"/w/{session.workspace_id}/ops",
            json=encode_all(session.device.next_envelope(session.workspace_id)),
            headers=session.headers,
        )
        assert response.status_code == 200, response.text

        deadline = asyncio.get_running_loop().time() + 0.5
        while asyncio.get_running_loop().time() < deadline:
            try:
                frames.append(await _next_text_frame(ws))
            except TimeoutError:
                continue

    assert set(frames) <= {"", KEEPALIVE_FRAME}, frames
    assert "" in frames, "expected at least the handshake poke"
    assert KEEPALIVE_FRAME in frames, "expected at least one keepalive over the idle stretch"


async def _next_text_frame(ws: AsyncWebSocketSession, timeout: float = 0.1) -> str:
    event = await ws.receive(timeout=timeout)
    assert not isinstance(event, BytesMessage), "the signal socket never sends bytes"
    assert isinstance(event, TextMessage), f"unexpected frame {event!r}"
    return event.data


# --- Revocation --------------------------------------------------------------


async def _revoke_own_owner_grant(client: AsyncClient, session: Session) -> Response:
    """Post a Root-signed Revoke of this device's own owner Grant.

    Root-signed because only Root may unmake an ``owner`` Grant (ADR-0031) — which
    is the same reason revoking a Device takes the passphrase.  Authored by the
    device itself, which is fine and is the point: the authority is Root's, and the
    envelope author only has to be a Member the log knows.
    """
    assert session.owner_grant_id is not None
    certificate = session.root.revoke_certificate(
        session.workspace_id,
        grant_id=session.owner_grant_id,
        revoker_member_id=session.device.member_id,
    )
    envelope = session.advance_control_head(
        session.root.revoke_envelope(
            session.device,
            session.workspace_id,
            certificate=certificate,
            prev_control_hash=session.control_head,
        )
    )
    return await client.post(
        f"/w/{session.workspace_id}/ops",
        json=encode_all(envelope),
        headers=session.headers,
    )


async def test_a_revocation_closes_the_live_socket_with_4403(
    http_client: AsyncClient, hub: SignalHub, session: Session
) -> None:
    """The third branch of the pump, over a real socket.

    A socket is authenticated once, at the handshake, and never re-checked — so
    losing the last live Grant has to reach an *already open* one, or a revoked
    subscriber goes on learning that activity exists in the Workspace, which is
    exactly the metadata the payload-free poke exists not to leak.

    ``4403`` and not a bare disconnect: a revoked subscriber should learn why its
    socket ended, and the code is the one the handshake would have refused it with,
    so the client's reconnect ladder needs no new branch.
    """
    async with subscribe(session.workspace_id, session.member_token) as ws:
        assert hub.subscriber_count(session.workspace_id) == 1

        revoked = await _revoke_own_owner_grant(http_client, session)
        assert revoked.status_code == 200, revoked.text

        with pytest.raises(WebSocketDisconnect) as closed:
            await ws.receive(timeout=FRAME_TIMEOUT_SECONDS)
    assert closed.value.code == SIGNAL_CLOSE_FORBIDDEN

    # The hub holds subscriptions and nothing else, so a closed socket must leave
    # no handle behind — a revocation that leaked one would be a slow resource
    # drain triggerable by an ordinary control op.
    for _ in range(50):
        if hub.subscriber_count(session.workspace_id) == 0:
            break
        await asyncio.sleep(0.02)
    assert hub.subscriber_count(session.workspace_id) == 0


async def test_a_revoked_member_cannot_open_a_socket(
    http_client: AsyncClient, session: Session
) -> None:
    """The other half: the door stays shut, not just this one socket.

    The handshake is held to the member-GET bar — an *unrevoked* member token —
    which is what admits a pre-grant device during enrolment and refuses a revoked
    one immediately.  The access token itself is still perfectly valid, so without
    this check a revoked Device would simply reconnect and carry on.
    """
    revoked = await _revoke_own_owner_grant(http_client, session)
    assert revoked.status_code == 200, revoked.text

    async with subscribe(
        session.workspace_id, session.member_token, expect_initial_poke=False
    ) as ws:
        with pytest.raises(WebSocketDisconnect) as refusal:
            await ws.receive(timeout=FRAME_TIMEOUT_SECONDS)
    # Not 4401: the credential authenticates fine, it simply authorizes nothing.
    assert refusal.value.code == SIGNAL_CLOSE_FORBIDDEN


# --- Lifecycle ---------------------------------------------------------------


async def test_disconnect_unsubscribes(
    http_client: AsyncClient, hub: SignalHub, session: Session
) -> None:
    async with subscribe(session.workspace_id, session.member_token):
        assert hub.subscriber_count(session.workspace_id) == 1

    # The hub holds subscriptions and nothing else, so a dropped socket must
    # leave it empty rather than leaking a handle per reconnect.
    for _ in range(50):
        if hub.subscriber_count(session.workspace_id) == 0:
            break
        await asyncio.sleep(0.02)
    assert hub.subscriber_count(session.workspace_id) == 0
