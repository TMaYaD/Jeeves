"""The endpoints of the Minimal Sync Server walking skeleton.

Every check here is content-blind: the server reads the 158-byte header and the
Member registry, and never a body.  Body-level rules (padding, payload shape)
are the pulling client's duty — under suite 0x01 the server could not run them
even if it wanted to, so it does not run them now either.  The realtime signal
socket is content-blind in the strongest sense available: a poke is a
zero-length frame, so the channel carries no seq, no author and no count.

Authorization is the stub #549 replaces: a User has exactly one implicit
Workspace, derived from the user id, and the Grants index that will decide this
question does not exist yet.  Transport auth is the existing user JWT resolved
through ``resolve_member_token``; #548 swaps that one function to member-scoped
tokens and turns ``header.author_member_id in user's members`` into
``jwt.member == header.author``.  Signal sockets are authenticated once, at the
handshake, and never re-checked: #549 therefore owes not only the Grants index
but **closing live signal sockets when a grant is revoked**, since until it does
a revoked subscriber keeps learning that activity exists in the Workspace.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import uuid
from contextlib import suppress
from datetime import UTC, datetime

from fastapi import (
    APIRouter,
    Depends,
    HTTPException,
    Query,
    Response,
    WebSocket,
    WebSocketDisconnect,
    status,
)
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_member, resolve_member_token
from app.auth.models import User
from app.config import settings
from app.database import get_db
from app.sync.envelope import (
    MINIMUM_ENVELOPE_BYTES,
    SIGN_PUBLIC_KEY_BYTES,
    EnvelopeError,
    EnvelopeTooShortError,
    OpHeader,
    check_served,
    derive_key_id,
)
from app.sync.ids import implicit_workspace_id
from app.sync.models import Member, Op
from app.sync.schemas import (
    MemberListResponse,
    MemberOut,
    MemberRegisterRequest,
    OpResult,
    PostOpsRequest,
    PostOpsResponse,
    PulledOp,
    PullOpsResponse,
)
from app.sync.signal_hub import SignalHub, SignalSubscription, get_signal_hub

router = APIRouter()

# not configurable: transport paging, sized for the harness and for a first
# real device bootstrap.  Tune here if a fleet ever needs it, not per request.
DEFAULT_OPS_PAGE_LIMIT = 500
MAX_OPS_PAGE_LIMIT = 1000
#: Guards the single-transaction batch from an unbounded request body.
MAX_OPS_PER_BATCH = 1000

#: The only non-empty frame the signal socket ever sends.  Application-level
#: rather than a WebSocket protocol PING because protocol pings are unobservable
#: from a browser client, and the client needs to see liveness on every platform.
KEEPALIVE_FRAME = "ping"

# not configurable: application close codes for the signal socket, mirroring the
# HTTP statuses their causes would produce.  The client's reconnect ladder
# branches on these exact numbers, so they are protocol, not policy.
SIGNAL_CLOSE_PROTOCOL_ERROR = 4400
SIGNAL_CLOSE_UNAUTHENTICATED = 4401
SIGNAL_CLOSE_FORBIDDEN = 4403


def _authorize_workspace(workspace_id: uuid.UUID, user: User) -> None:
    """Stub Grant check: a User reaches exactly their own implicit Workspace."""
    if workspace_id != implicit_workspace_id(user.id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="No grant for this workspace",
        )


def _decode_base64(value: str, what: str) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=f"{what} is not valid base64",
        ) from exc


@router.post("/members", response_model=MemberOut, status_code=status.HTTP_201_CREATED)
async def register_member(
    body: MemberRegisterRequest,
    response: Response,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_member),
) -> MemberOut:
    sign_pk = _decode_base64(body.sign_pk, "sign_pk")
    if len(sign_pk) != SIGN_PUBLIC_KEY_BYTES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail=f"sign_pk must be {SIGN_PUBLIC_KEY_BYTES} bytes",
        )
    key_id = derive_key_id(sign_pk)
    if body.key_id is not None and _decode_base64(body.key_id, "key_id") != key_id:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="key_id does not match the derivation from sign_pk",
        )

    existing = await db.get(Member, body.member_id)
    if existing is not None:
        if existing.user_id != current_user.id or existing.sign_pk != sign_pk:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Member id already registered with a different key",
            )
        response.status_code = status.HTTP_200_OK
        return _member_out(existing)

    member = Member(
        member_id=body.member_id,
        user_id=current_user.id,
        sign_pk=sign_pk,
        key_id=key_id,
    )
    db.add(member)
    await db.commit()
    return _member_out(member)


def _member_out(member: Member) -> MemberOut:
    return MemberOut(
        member_id=member.member_id,
        sign_pk=base64.b64encode(member.sign_pk).decode("ascii"),
        key_id=base64.b64encode(member.key_id).decode("ascii"),
    )


@router.get("/w/{workspace_id}/members", response_model=MemberListResponse)
async def list_workspace_members(
    workspace_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_member),
) -> MemberListResponse:
    _authorize_workspace(workspace_id, current_user)
    rows = (
        (await db.execute(select(Member).where(Member.user_id == current_user.id))).scalars().all()
    )
    return MemberListResponse(members=[_member_out(row) for row in rows])


@router.post("/w/{workspace_id}/ops", response_model=PostOpsResponse)
async def post_ops(
    workspace_id: uuid.UUID,
    body: PostOpsRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_member),
    hub: SignalHub = Depends(get_signal_hub),
) -> PostOpsResponse:
    _authorize_workspace(workspace_id, current_user)
    if len(body.ops) > MAX_OPS_PER_BATCH:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail=f"Batch exceeds {MAX_OPS_PER_BATCH} ops",
        )

    parsed: list[tuple[bytes, OpHeader]] = []
    for index, encoded in enumerate(body.ops):
        envelope = _decode_base64(encoded, f"ops[{index}]")
        try:
            header = OpHeader.parse(envelope)
            if len(envelope) < MINIMUM_ENVELOPE_BYTES:
                # The one body-shaped rule a content-blind server can apply: it
                # follows from the padding size classes alone, so refusing here
                # costs no look at the body and keeps unstorable bytes out of
                # the log rather than leaving every puller to quarantine them.
                raise EnvelopeTooShortError(
                    f"envelope is {len(envelope)} bytes, the shortest legal one "
                    f"is {MINIMUM_ENVELOPE_BYTES}"
                )
            check_served(header)
        except EnvelopeError as exc:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail=f"ops[{index}]: {exc.reason}",
            ) from exc
        if header.workspace_id != workspace_id:
            # The index columns are a pure index cross-checked against the
            # envelope bytes, never trusted over them (review F6).
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail=f"ops[{index}]: workspace_mismatch",
            )
        parsed.append((envelope, header))

    if not parsed:
        return PostOpsResponse(results=[])

    authors = {header.author_member_id for _, header in parsed}
    known_members = {
        member.member_id: member
        for member in (await db.execute(select(Member).where(Member.member_id.in_(authors))))
        .scalars()
        .all()
    }
    for author in authors:
        member = known_members.get(author)
        if member is None or member.user_id != current_user.id:
            # The shape that becomes `jwt.member == header.author` in #548.
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Author is not a member registered to this user",
            )

    try:
        results = await _append_batch(db, workspace_id, parsed)
    except IntegrityError:
        # The author-chain constraint fired: another request for the same author
        # committed between this one's MAX(author_seq) read and its insert.  The
        # read is now stale by definition, so discard it and resolve once more
        # against what is actually committed — a concurrent *replay* comes back
        # as duplicate: true, and a genuine fork as the same 409 a sequential
        # gap gets.  Never a 500: the client's move is to re-pull either way.
        await db.rollback()
        try:
            results = await _append_batch(db, workspace_id, parsed)
        except IntegrityError as exc:
            await db.rollback()
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="author_chain_conflict: a concurrent write took this author_seq",
            ) from exc

    await db.commit()
    if any(not result.duplicate for result in results):
        # After the commit, never before: a subscriber woken by a poke pulls
        # immediately, and pulling against an uncommitted transaction would
        # return nothing and burn the poke.  A pure-duplicate replay is not news.
        hub.notify(workspace_id)
    return PostOpsResponse(results=results)


async def _append_batch(
    db: AsyncSession,
    workspace_id: uuid.UUID,
    parsed: list[tuple[bytes, OpHeader]],
) -> list[OpResult]:
    """Resolve the batch against what is stored, stage the new ops, flush.

    Split out from the endpoint so the whole read-then-write step can be retried
    verbatim after the uniqueness constraint rejects a raced insert.  Raises
    ``IntegrityError`` when it does; commits nothing.
    """
    authors = {header.author_member_id for _, header in parsed}
    existing_seq_by_key: dict[tuple[uuid.UUID, uuid.UUID], int] = {
        (row.author_member_id, row.op_id): row.seq
        for row in (
            await db.execute(
                select(Op).where(
                    Op.workspace_id == workspace_id,
                    Op.op_id.in_({header.op_id for _, header in parsed}),
                )
            )
        )
        .scalars()
        .all()
    }
    last_author_seq: dict[uuid.UUID, int] = {
        author_member_id: last_seq
        for author_member_id, last_seq in (
            await db.execute(
                select(Op.author_member_id, func.max(Op.author_seq))
                .where(
                    Op.workspace_id == workspace_id,
                    Op.author_member_id.in_(authors),
                )
                .group_by(Op.author_member_id)
            )
        ).all()
    }

    received_at = datetime.now(UTC)
    staged: dict[tuple[uuid.UUID, uuid.UUID], Op] = {}
    # Per op: (op_id, resolved seq or the staged op to read one off after the
    # flush, duplicate?).  A repeat inside one batch duplicates the op staged
    # earlier in the same request, exactly as a repeat across batches does.
    plan: list[tuple[uuid.UUID, int | Op, bool]] = []
    for index, (envelope, header) in enumerate(parsed):
        key = (header.author_member_id, header.op_id)
        if key in existing_seq_by_key:
            plan.append((header.op_id, existing_seq_by_key[key], True))
            continue
        if key in staged:
            plan.append((header.op_id, staged[key], True))
            continue
        expected_author_seq = last_author_seq.get(header.author_member_id, 0) + 1
        if header.author_seq != expected_author_seq:
            # The whole batch fails: a gap means the client's chain is broken,
            # and accepting the tail would make the break permanent.
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=(
                    f"ops[{index}]: author_seq {header.author_seq}, expected {expected_author_seq}"
                ),
            )
        op = Op(
            workspace_id=workspace_id,
            envelope=envelope,
            op_class=header.op_class,
            key_epoch=header.key_epoch,
            op_id=header.op_id,
            author_member_id=header.author_member_id,
            author_key_id=header.author_key_id,
            author_seq=header.author_seq,
            received_at=received_at,
        )
        db.add(op)
        staged[key] = op
        last_author_seq[header.author_member_id] = header.author_seq
        plan.append((header.op_id, op, False))

    await db.flush()
    return [
        OpResult(
            op_id=op_id,
            seq=entry if isinstance(entry, int) else entry.seq,
            duplicate=duplicate,
        )
        for op_id, entry, duplicate in plan
    ]


@router.get("/w/{workspace_id}/ops", response_model=PullOpsResponse)
async def pull_ops(
    workspace_id: uuid.UUID,
    since: int = Query(default=0, ge=0),
    limit: int = Query(default=DEFAULT_OPS_PAGE_LIMIT, ge=1, le=MAX_OPS_PAGE_LIMIT),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_member),
) -> PullOpsResponse:
    """``since`` is a pure client parameter — no cursor is persisted (review F17)."""
    _authorize_workspace(workspace_id, current_user)
    rows = (
        (
            await db.execute(
                select(Op)
                .where(
                    Op.workspace_id == workspace_id,
                    Op.seq > since,
                    Op.compacted_by.is_(None),
                )
                .order_by(Op.seq)
                .limit(limit + 1)
            )
        )
        .scalars()
        .all()
    )
    has_more = len(rows) > limit
    return PullOpsResponse(
        ops=[
            PulledOp(seq=row.seq, envelope=base64.b64encode(row.envelope).decode("ascii"))
            for row in rows[:limit]
        ],
        has_more=has_more,
    )


@router.websocket("/w/{workspace_id}/signal")
async def signal_socket(
    websocket: WebSocket,
    workspace_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    hub: SignalHub = Depends(get_signal_hub),
) -> None:
    """Payload-free "there is news" push for one Workspace.

    A poke is a **zero-length text frame** and always means the same thing: run
    a sync from your cursor now.  The Workspace lives in the URL path, so no
    frame ever carries an envelope, a seq, an author or a count — the socket
    reveals only that activity happened, which is strictly less than the pull
    the client then performs already reveals.

    The client sends the bearer token as its **first frame**: a browser cannot
    set an ``Authorization`` header on a WebSocket, and a query string would put
    the token in proxy and server logs.  A successful handshake is acknowledged
    with an immediate poke, which doubles as the catch-up trigger — whatever was
    appended while this client was away is swept up by the pull it provokes, so
    the server needs no memory of who has seen what.
    """
    await websocket.accept()

    try:
        token = await asyncio.wait_for(
            websocket.receive_text(),
            timeout=settings.signal_auth_frame_deadline_seconds,
        )
    except (TimeoutError, WebSocketDisconnect, KeyError):
        # No auth frame in time, a close instead of one, or a binary frame where
        # text was required — all the same protocol violation.
        await _close_quietly(websocket, SIGNAL_CLOSE_PROTOCOL_ERROR)
        return

    try:
        principal = await resolve_member_token(token, db)
    except HTTPException:
        await _close_quietly(websocket, SIGNAL_CLOSE_UNAUTHENTICATED)
        return
    try:
        _authorize_workspace(workspace_id, principal)
    except HTTPException:
        await _close_quietly(websocket, SIGNAL_CLOSE_FORBIDDEN)
        return

    with hub.subscribe(workspace_id) as subscription:
        # FastAPI only observes a client close while a read is pending, so the
        # socket is drained concurrently with the send loop.  Inbound frames
        # after the handshake are ignored: the client has nothing to say here.
        reader = asyncio.create_task(_drain_until_disconnect(websocket))
        try:
            await websocket.send_text("")
            await _pump_signals(websocket, subscription, reader)
        except (WebSocketDisconnect, RuntimeError):
            # The peer went away mid-send; nothing left to do but stop.
            pass
        finally:
            reader.cancel()
            with suppress(asyncio.CancelledError, WebSocketDisconnect, RuntimeError):
                await reader


async def _close_quietly(websocket: WebSocket, code: int) -> None:
    with suppress(RuntimeError, WebSocketDisconnect):
        await websocket.close(code=code)


async def _drain_until_disconnect(websocket: WebSocket) -> None:
    """Read and discard until the peer goes away.

    Its completion is how the send loop learns the socket is gone: Starlette
    only surfaces a close while a read is pending.
    """
    with suppress(WebSocketDisconnect, RuntimeError):
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                return


async def _pump_signals(
    websocket: WebSocket,
    subscription: SignalSubscription,
    reader: asyncio.Task[None],
) -> None:
    """One loop, two frame kinds, nothing else — ever.

    The keepalive is the *timeout branch* of the same wait that delivers pokes,
    so it fires only in the absence of news.  That makes it the exact complement
    of what a poke reveals ("no activity right now"), which is why an
    application-level heartbeat adds nothing to the leak surface.
    """
    while not reader.done():
        waiter = asyncio.create_task(subscription.wait())
        try:
            done, _ = await asyncio.wait(
                {waiter, reader},
                timeout=settings.signal_keepalive_interval_seconds,
                return_when=asyncio.FIRST_COMPLETED,
            )
        finally:
            if not waiter.done():
                waiter.cancel()
        if reader in done:
            return
        if waiter in done:
            # Cleared before the send, so an append racing this line pokes again
            # rather than being swallowed by the frame already on its way.
            subscription.clear()
            await websocket.send_text("")
        else:
            await websocket.send_text(KEEPALIVE_FRAME)
