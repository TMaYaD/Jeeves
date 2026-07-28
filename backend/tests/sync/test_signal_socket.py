"""The realtime signal contract: `WS /w/{w}/signal`.

`app/test/sync/fake_sync_server_contract_test.dart` mirrors the cases that the
in-process fake can express, under the same names.  Three cases have no twin —
bad token, missing auth frame, keepalive — because the fake has no token model
and no wall clock; they are backend-only by construction, and the fake's
`emittedSignalFrames` check is a fidelity smoke test rather than the wire
assertion.  **The load-bearing no-payload assertion lives here**: every poke is
a zero-length *text* frame, every keepalive is exactly ``KEEPALIVE_FRAME``, and
the socket never sends anything else.

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
from httpx import ASGITransport, AsyncClient
from httpx_ws import AsyncWebSocketSession, WebSocketDisconnect, aconnect_ws
from httpx_ws.transport import ASGIWebSocketTransport
from sqlalchemy.ext.asyncio import AsyncSession
from wsproto.events import BytesMessage, TextMessage

from app.config import settings
from app.database import get_db
from app.main import app
from app.sync.ids import implicit_workspace_id
from app.sync.routes import (
    KEEPALIVE_FRAME,
    SIGNAL_CLOSE_FORBIDDEN,
    SIGNAL_CLOSE_PROTOCOL_ERROR,
    SIGNAL_CLOSE_UNAUTHENTICATED,
)
from app.sync.signal_hub import SignalHub, get_signal_hub
from tests.conftest import auth_header, register
from tests.sync.builders import SpecDevice, encode_all, user_id_from_token

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


class Session:
    """One authenticated user with one registered device."""

    def __init__(self, token: str, workspace_id: uuid.UUID, device: SpecDevice) -> None:
        self.token = token
        self.workspace_id = workspace_id
        self.device = device

    @property
    def headers(self) -> dict[str, str]:
        return auth_header(self.token)


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
async def http_client(db: AsyncSession, hub: SignalHub) -> AsyncIterator[AsyncClient]:
    """The writer side: plain HTTP over the app, on the test's transaction.

    Installing the overrides here is what also binds the sockets opened by
    :func:`subscribe` to this same session and this same hub.
    """

    async def override_get_db() -> AsyncIterator[AsyncSession]:
        yield db

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_signal_hub] = lambda: hub
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        yield client
    app.dependency_overrides.clear()


async def _open_session(client: AsyncClient, email: str) -> Session:
    token = await register(client, email)
    device = SpecDevice()
    response = await client.post(
        "/members", json=device.registration_body(), headers=auth_header(token)
    )
    assert response.status_code == 201, response.text
    return Session(token, implicit_workspace_id(user_id_from_token(token)), device)


@pytest_asyncio.fixture
async def session(http_client: AsyncClient) -> Session:
    return await _open_session(http_client, "signal-owner@example.com")


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
    async with subscribe(session.workspace_id, session.token):
        pass


async def test_subscribe_to_another_workspace_is_refused_with_4403(
    http_client: AsyncClient, session: Session
) -> None:
    async with subscribe(uuid.uuid4(), session.token, expect_initial_poke=False) as ws:
        with pytest.raises(WebSocketDisconnect) as refusal:
            await ws.receive(timeout=FRAME_TIMEOUT_SECONDS)
    assert refusal.value.code == SIGNAL_CLOSE_FORBIDDEN


async def test_a_bad_token_is_refused_with_4401(http_client: AsyncClient, session: Session) -> None:
    async with subscribe(session.workspace_id, "not-a-jwt", expect_initial_poke=False) as ws:
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
    async with subscribe(session.workspace_id, session.token) as ws:
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

    async with subscribe(session.workspace_id, session.token) as ws:
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
    neighbour = await _open_session(http_client, "signal-neighbour@example.com")

    async with subscribe(neighbour.workspace_id, neighbour.token) as ws:
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
    async with subscribe(session.workspace_id, session.token) as ws:
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
    async with subscribe(session.workspace_id, session.token, expect_initial_poke=False) as ws:
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


# --- Lifecycle ---------------------------------------------------------------


async def test_disconnect_unsubscribes(
    http_client: AsyncClient, hub: SignalHub, session: Session
) -> None:
    async with subscribe(session.workspace_id, session.token):
        assert hub.subscriber_count(session.workspace_id) == 1

    # The hub holds subscriptions and nothing else, so a dropped socket must
    # leave it empty rather than leaking a handle per reconnect.
    for _ in range(50):
        if hub.subscriber_count(session.workspace_id) == 0:
            break
        await asyncio.sleep(0.02)
    assert hub.subscriber_count(session.workspace_id) == 0
