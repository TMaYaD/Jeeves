"""The Minimal Sync Server's HTTP and WebSocket surface.

Content ops stay opaque: the server reads the 158-byte header and never a body.
**Control ops are the deliberate exception** — ``op_class=2`` payloads are
unencrypted precisely so the server can check that a Member was registered by
Root before it materialises the membership (ADR-0028, review F2).  That is the
only body-reading path here, and it is fail-closed at every step.  The realtime
signal socket is content-blind in the strongest sense available: a poke is a
zero-length frame, so the channel carries no seq, no author and no count.

Transport auth is member-scoped, and uniformly so.  The sync data routes
(``GET``/``POST /w/{w}/ops``, ``GET /w/{w}/members``) and the signal socket
(``WS /w/{w}/signal``) all resolve identity through ``resolve_member_token``,
which accepts only a token issued by the proof-of-possession exchange in
``app.sync.member_auth``; every posted op must additionally name that same
member as its author.  The socket is held to the same bar as the routes on
purpose — a socket that took a plain user token would be the weak door, and
learning that activity is happening in a Workspace is not something a stolen
user session should be able to subscribe to.  ``POST /members`` and the recovery
escrow routes take the User credential instead, because they are what a Device
uses *before* it has a member credential.

**Workspace authorization splits three ways**, and the split is load-bearing:

* **User-credential routes** (the recovery escrow) admit a ``workspace_id`` in
  ``derivable_workspace_ids(user_id)`` — the default Workspace and the implicit
  ``user_preferences`` one.  They are pre-genesis by necessity: the escrow slot
  is what establishes the ``root_pk`` a genesis op is then verified against.
* **Member GET routes** (``GET /w/{w}/ops``, ``GET /w/{w}/members``, the signal
  handshake) admit any **unrevoked** member token whose User derives the
  Workspace — *no Grant required*.  "Revoked" is index-defined: a Member with at
  least one grant row and none live is refused and its sockets closed.  A
  *pre-grant* Member (zero grant rows) is admitted, which is what lets the
  enrolment ceremony pull and apply the control log before it holds any Grant,
  and it reopens nothing — reads were always User-scoped by derivation, and the
  storage-DoS closure lives on the write path.  Likewise a **pre-genesis GET
  returns an empty page**, never an error: ``workspace_not_created`` is scoped to
  POST paths only, because the empty-log observation is exactly what the
  ceremony branches on.
* **Member content POSTs** require a **live Grant** and dispatch on
  ``(grant.role, header.op_class)``.  A root-signed control payload lands
  regardless of Grants — that is how an ungranted device's register-plus-grant
  batch gets in at all — and everything else needs a role the matrix admits.

Materialising a Revoke does three things in one breath: stamp
``grants.revoked_by_seq``, kill the Member's refresh tokens when it has no live
Grant left, and **close its live signal sockets**.  The last one matters because
a socket is authenticated once, at the handshake, and never re-checked; without
it a revoked subscriber would keep learning that activity exists in the
Workspace.

**Error details.** Every rejection this module raises carries a structured
detail — ``{"code": <snake_case>, ...}`` — and a per-op rejection on
``POST /w/{w}/ops`` additionally carries the zero-based batch ``index`` of the
offending op, so a client can point at the op rather than parsing prose.  The
socket cannot carry a body, so its refusals are application close codes
mirroring the HTTP statuses their causes would produce.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import uuid
from contextlib import suppress
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, cast

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
from redis.asyncio import Redis
from sqlalchemy import CursorResult, func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_member, get_current_user, resolve_member_token
from app.auth.models import RefreshToken, User
from app.auth.schemas import RefreshRequest, Token
from app.auth.tokens import create_access_token, create_refresh_token, hash_refresh_token
from app.config import settings
from app.database import get_db
from app.redis import get_redis
from app.sync.control_payload import (
    CONTROL_TYPE_GRANT,
    CONTROL_TYPE_MEMBER_REGISTER,
    CONTROL_TYPE_REVOKE,
    CONTROL_TYPE_WORKSPACE_GENESIS,
    GRANTER_ROOT,
    KEX_PUBLIC_KEY_BYTES,
    MEMBER_KIND_DEVICE,
    ROLE_OP_CLASS_MATRIX,
    ROLE_OWNER,
    ZERO_PREV_CONTROL_HASH,
    ControlPayload,
    ControlPayloadError,
    GenesisCertificate,
    GrantCertificate,
    RegistrationCertificate,
    RevokeCertificate,
    UnsupportedControlTypeError,
    verify_genesis_certificate,
    verify_grant_certificate,
    verify_registration_certificate,
    verify_revoke_certificate,
)
from app.sync.envelope import (
    MINIMUM_ENVELOPE_BYTES,
    OP_CLASS_CONTROL,
    SIGN_PUBLIC_KEY_BYTES,
    EnvelopeError,
    EnvelopeTooShortError,
    OpHeader,
    check_served,
    derive_key_id,
    parse_body,
    split_envelope,
)
from app.sync.escrow import (
    FIRST_ESCROW_VERSION,
    MAX_ESCROW_VERSION,
    NO_ESCROW_STORED_VERSION,
    RECOVERY_FETCH_DAILY_LIMIT,
    ROOT_PUBLIC_KEY_BYTES,
    ROOT_SIGNATURE_BYTES,
    EscrowSignatureError,
    count_recovery_fetch,
    recovery_fetch_retry_after_seconds,
    verify_escrow_signature,
)
from app.sync.ids import derivable_workspace_ids, user_preferences_workspace_id
from app.sync.member_auth import (
    MEMBER_CHALLENGE_NONCE_BYTES,
    TOKEN_USE_MEMBER,
    MemberChallengeError,
    consume_member_challenge,
    count_member_challenge,
    create_member_challenge,
    member_challenge_retry_after_seconds,
    verify_member_challenge,
)
from app.sync.models import Grant, Member, Op, RecoveryEscrow, RecoveryEscrowFetch, Workspace
from app.sync.schemas import (
    MemberChallengeResponse,
    MemberListResponse,
    MemberOut,
    MemberRegisterRequest,
    MemberTokenRequest,
    OpResult,
    PostOpsRequest,
    PostOpsResponse,
    PulledOp,
    PullOpsResponse,
    RecoveryEscrowRequest,
    RecoveryEscrowResponse,
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


def _require_derivable_workspace(workspace_id: uuid.UUID, user_id: str) -> None:
    """The outermost gate on every Workspace route.

    A User reaches the two Workspaces their id derives — the default one and the
    implicit ``user_preferences`` one — and nothing else.  This is not a Grant
    check: it is the v1 rule that keeps the Workspace id space closed, and real
    user-created Workspaces will lift it by resolving membership instead.
    """
    if workspace_id not in derivable_workspace_ids(user_id):
        raise _forbidden("workspace_not_derivable")


async def _refuse_if_revoked(db: AsyncSession, workspace_id: uuid.UUID, member: Member) -> None:
    """The member-GET gate: an unrevoked member token is enough.

    Revocation is index-defined — at least one grant row and none live — so a
    *pre-grant* Member is admitted and a revoked one is refused immediately, on
    reads as well as writes.  That immediacy is half of AC 1; the other half is
    the client's own authorization stage, which does not consult the server.

    Scoped to the calling Member rather than going through :func:`_grant_index`:
    the verdict needs only "any row" and "any live row", both of which
    ``ix_grants_workspace_member`` answers directly.  Loading every Grant in the
    Workspace would make this a full scan on every pull and every socket
    handshake, growing with the Workspace's member and rotation count.  The
    whole-workspace walk stays where it is genuinely needed, in
    :func:`_verify_and_authorize`, which judges a batch positionally.
    """
    live_by_grant = (
        (
            await db.execute(
                select(Grant.revoked_by_seq).where(
                    Grant.workspace_id == workspace_id,
                    Grant.member_id == member.member_id,
                )
            )
        )
        .scalars()
        .all()
    )
    if live_by_grant and all(revoked_by_seq is not None for revoked_by_seq in live_by_grant):
        raise _forbidden("no_live_grant", revoked=True)


def _forbidden(code: str, **fields: Any) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail={"code": code, **fields},
    )


def _conflict(code: str, **fields: Any) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail={"code": code, **fields},
    )


def _unprocessable(code: str, **fields: Any) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        detail={"code": code, **fields},
    )


@dataclass(slots=True)
class _GrantState:
    member_id: uuid.UUID
    role: str
    revoked: bool


class _GrantIndex:
    """The ``grants`` rows for one Workspace, walked forward in batch order.

    The server materialises a batch's control ops in the order they arrive, so a
    Grant authored at index 1 counts for a content op at index 2 of the same POST.
    Holding the walk in memory is what makes that true without flushing between
    ops — and it is the same "validity at the log position of signing" rule the
    client applies to its own derived view.
    """

    def __init__(self, rows: list[Grant]) -> None:
        self._states: dict[uuid.UUID, _GrantState] = {
            row.grant_id: _GrantState(
                member_id=row.member_id, role=row.role, revoked=row.revoked_by_seq is not None
            )
            for row in rows
        }

    def state(self, grant_id: uuid.UUID) -> _GrantState | None:
        return self._states.get(grant_id)

    def live_roles(self, member_id: uuid.UUID) -> set[str]:
        return {
            state.role
            for state in self._states.values()
            if state.member_id == member_id and not state.revoked
        }

    def has_any_grant(self, member_id: uuid.UUID) -> bool:
        return any(state.member_id == member_id for state in self._states.values())

    def is_revoked(self, member_id: uuid.UUID) -> bool:
        """At least one grant row, none of them live."""
        return self.has_any_grant(member_id) and not self.live_roles(member_id)

    def add(self, grant_id: uuid.UUID, member_id: uuid.UUID, role: str) -> None:
        self._states[grant_id] = _GrantState(member_id=member_id, role=role, revoked=False)

    def revoke(self, grant_id: uuid.UUID) -> None:
        state = self._states.get(grant_id)
        if state is not None:
            state.revoked = True


async def _grant_index(db: AsyncSession, workspace_id: uuid.UUID) -> _GrantIndex:
    rows = (
        (await db.execute(select(Grant).where(Grant.workspace_id == workspace_id))).scalars().all()
    )
    return _GrantIndex(list(rows))


def _decode_base64(value: str, code: str, **fields: Any) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise _unprocessable(code, **fields) from exc


# ── Member registry ───────────────────────────────────────────────────────────


@router.post("/members", response_model=MemberOut, status_code=status.HTTP_201_CREATED)
async def register_member(
    body: MemberRegisterRequest,
    response: Response,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> MemberOut:
    """Store a Device's public keys under the User credential.

    This confers **no authority** — the row is an unchained shell until a
    Root-signed MemberRegister lands in the log.  A stolen user credential can
    reach this endpoint and gain nothing an honest client will honour.
    """
    sign_pk = _decode_base64(body.sign_pk, "malformed_sign_pk")
    if len(sign_pk) != SIGN_PUBLIC_KEY_BYTES:
        raise _unprocessable("malformed_sign_pk", expected_bytes=SIGN_PUBLIC_KEY_BYTES)
    kex_pk: bytes | None = None
    if body.kex_pk is not None:
        kex_pk = _decode_base64(body.kex_pk, "malformed_kex_pk")
        if len(kex_pk) != KEX_PUBLIC_KEY_BYTES:
            raise _unprocessable("malformed_kex_pk", expected_bytes=KEX_PUBLIC_KEY_BYTES)
    key_id = derive_key_id(sign_pk)
    if body.key_id is not None and _decode_base64(body.key_id, "malformed_key_id") != key_id:
        raise _unprocessable("key_id_not_derived_from_sign_pk")

    existing = await db.get(Member, body.member_id)
    if existing is not None:
        if existing.user_id != current_user.id or existing.sign_pk != sign_pk:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={"code": "member_id_already_registered"},
            )
        if kex_pk is not None and existing.kex_pk != kex_pk:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={"code": "member_id_already_registered"},
            )
        response.status_code = status.HTTP_200_OK
        return _member_out(existing)

    member = Member(
        member_id=body.member_id,
        user_id=current_user.id,
        sign_pk=sign_pk,
        key_id=key_id,
        kex_pk=kex_pk,
    )
    db.add(member)
    await db.commit()
    return _member_out(member)


def _member_out(member: Member) -> MemberOut:
    return MemberOut(
        member_id=member.member_id,
        sign_pk=base64.b64encode(member.sign_pk).decode("ascii"),
        key_id=base64.b64encode(member.key_id).decode("ascii"),
        kex_pk=(
            base64.b64encode(member.kex_pk).decode("ascii") if member.kex_pk is not None else None
        ),
        chained=member.chained_at is not None,
    )


@router.get("/w/{workspace_id}/members", response_model=MemberListResponse)
async def list_workspace_members(
    workspace_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    current_member: Member = Depends(get_current_member),
) -> MemberListResponse:
    """A bootstrap hint, and nothing a client's verification reads.

    Chain-gating means a Member's key is learned from its own Root-signed
    MemberRegister in the log, never from this list.  Poisoning it is inert.
    """
    _require_derivable_workspace(workspace_id, current_member.user_id)
    await _refuse_if_revoked(db, workspace_id, current_member)
    rows = (
        (await db.execute(select(Member).where(Member.user_id == current_member.user_id)))
        .scalars()
        .all()
    )
    return MemberListResponse(members=[_member_out(row) for row in rows])


# ── Member-scoped transport auth ──────────────────────────────────────────────


@router.post("/members/{member_id}/challenge", response_model=MemberChallengeResponse)
async def issue_member_challenge(
    member_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    redis: Redis = Depends(get_redis),
) -> MemberChallengeResponse:
    """Hand out a single-use nonce for a Device to sign.

    Unauthenticated on purpose: possession of the Device's signing key *is* the
    credential being proved, and a random nonce discloses nothing.  Being
    unauthenticated is also why it is rate-limited: nothing else bounds how many
    nonces one member id can mint, and each one is a Redis key held for
    ``MEMBER_CHALLENGE_TTL_SECONDS``.

    The existence check runs first, so the counter is only ever created for a
    member that exists — an id-enumeration sweep cannot fill Redis with counters
    for uuids that were never registered.
    """
    if await db.get(Member, member_id) is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "unknown_member"},
        )
    if await count_member_challenge(redis, member_id) > settings.member_challenge_daily_limit:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={
                "code": "member_challenge_rate_limited",
                "retry_after_seconds": await member_challenge_retry_after_seconds(redis, member_id),
            },
        )
    return MemberChallengeResponse(nonce=await create_member_challenge(redis, member_id))


@router.post("/members/{member_id}/token", response_model=Token)
async def issue_member_token(
    member_id: uuid.UUID,
    body: MemberTokenRequest,
    db: AsyncSession = Depends(get_db),
    redis: Redis = Depends(get_redis),
) -> Token:
    """Exchange a signed challenge for a member-scoped access + refresh token."""
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail={"code": "bad_member_challenge"},
        headers={"WWW-Authenticate": "Bearer"},
    )
    member = await db.get(Member, member_id)
    if member is None:
        raise unauthorized
    owner = await db.get(User, member.user_id)
    if owner is None or not owner.is_active:
        raise unauthorized

    # GETDEL first, and *before* either field is decoded: a challenge is spent by
    # the attempt, win or lose, so a signature-guessing loop needs a fresh
    # round-trip for every guess — and an attempt this handler cannot even read
    # must not be the one shape that leaves the nonce alive to try again.
    stored = await consume_member_challenge(redis, body.nonce)
    # Undecodable base64 stays a 422 (see `test_a_nonce_that_is_not_base64...`):
    # every malformed *request* in this module answers 422 with a structured code,
    # and the distinction leaks nothing about the member or its key — only that
    # the bytes offered were not base64.
    nonce = _decode_base64(body.nonce, "bad_member_challenge")
    if len(nonce) != MEMBER_CHALLENGE_NONCE_BYTES:
        raise unauthorized
    signature = _decode_base64(body.signature, "bad_member_challenge")
    if stored is None or stored.get("member_id") != str(member_id):
        raise unauthorized
    try:
        verify_member_challenge(member_id, nonce, signature, member.sign_pk)
    except MemberChallengeError as exc:
        raise unauthorized from exc

    return await _issue_member_tokens(db, member)


@router.post("/members/{member_id}/token/refresh", response_model=Token)
async def refresh_member_token(
    member_id: uuid.UUID,
    body: RefreshRequest,
    db: AsyncSession = Depends(get_db),
) -> Token:
    """Rotate a member refresh token — same revoke-and-reissue as ``/session/refresh``."""
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail={"code": "invalid_refresh_token"},
        headers={"WWW-Authenticate": "Bearer"},
    )
    token_hash = hash_refresh_token(body.refresh_token)
    record = (
        await db.execute(select(RefreshToken).where(RefreshToken.token_hash == token_hash))
    ).scalar_one_or_none()

    now = datetime.now(UTC)
    if (
        record is None
        or record.member_id != member_id
        or record.revoked_at is not None
        or record.expires_at.replace(tzinfo=UTC) <= now
    ):
        raise unauthorized
    member = await db.get(Member, member_id)
    if member is None:
        raise unauthorized
    owner = await db.get(User, member.user_id)
    if owner is None or not owner.is_active:
        raise unauthorized

    record.revoked_at = now
    return await _issue_member_tokens(db, member)


async def _issue_member_tokens(db: AsyncSession, member: Member) -> Token:
    access_token = create_access_token(
        {
            "sub": str(member.member_id),
            "token_use": TOKEN_USE_MEMBER,
            "member_id": str(member.member_id),
            "user_id": member.user_id,
        }
    )
    raw_refresh, refresh_record = create_refresh_token(member.user_id, member_id=member.member_id)
    db.add(refresh_record)
    await db.commit()
    return Token(access_token=access_token, refresh_token=raw_refresh, token_type="bearer")


async def revoke_member_transport(db: AsyncSession, member_id: uuid.UUID) -> int:
    """Revoke every live refresh token scoped to ``member_id``; return how many.

    The mechanism behind "revoking a member kills its transport credential".
    #549's Revoke control op is the trigger; it only has to call this.
    """
    result = cast(
        CursorResult[Any],
        await db.execute(
            update(RefreshToken)
            .where(RefreshToken.member_id == member_id, RefreshToken.revoked_at.is_(None))
            .values(revoked_at=datetime.now(UTC))
        ),
    )
    await db.commit()
    return result.rowcount or 0


# ── Recovery escrow ───────────────────────────────────────────────────────────


@router.put("/w/{workspace_id}/recovery", response_model=RecoveryEscrowResponse)
async def put_recovery_escrow(
    workspace_id: uuid.UUID,
    body: RecoveryEscrowRequest,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> RecoveryEscrowResponse:
    """Write the passphrase-wrapped Root, under the User credential.

    The User credential gets the request *to* the slot; the Root signature is
    what gets it *into* the slot.  Once a record exists the signature is checked
    against the stored ``root_pk``, so a stolen user credential cannot overwrite
    the escrow (review F16).  The first write establishes ``root_pk`` — account
    creation writes the escrow in the same breath, and the pre-first-write race
    window is accepted and recorded.

    **The ceremony writes two slots**, the default Workspace's and the implicit
    ``user_preferences`` one, in that order — the same blob under two signatures,
    ``workspace_id`` being inside the preimage.  That doubles the pre-first-write
    TOFU window (two first-writes instead of one) under the same trust model, and
    is accepted for the same reason the window was accepted at all.  Recovery
    always reads the **default** slot, so a crash between the two PUTs leaves the
    recoverable one written.  Both slots exist because the server resolves a
    Workspace's ``root_pk`` from the slot of the Workspace being posted to, which
    keeps control verification uniform per Workspace and survives shared
    Workspaces without a shape change.
    """
    _require_derivable_workspace(workspace_id, current_user.id)
    blob = _decode_base64(body.blob_b64, "malformed_escrow_blob")
    root_sig = _decode_base64(body.root_sig_b64, "malformed_escrow_signature")
    root_pk = _decode_base64(body.root_pk_b64, "malformed_root_pk")
    if len(root_sig) != ROOT_SIGNATURE_BYTES:
        raise _unprocessable("malformed_escrow_signature", expected_bytes=ROOT_SIGNATURE_BYTES)
    if len(root_pk) != ROOT_PUBLIC_KEY_BYTES:
        raise _unprocessable("malformed_root_pk", expected_bytes=ROOT_PUBLIC_KEY_BYTES)
    if not FIRST_ESCROW_VERSION <= body.version <= MAX_ESCROW_VERSION:
        raise _unprocessable("malformed_escrow_version", version=body.version)

    stored = await db.get(RecoveryEscrow, (workspace_id, current_user.id))
    # A 403 rather than the 422 an op-level root-signature failure gets: there,
    # one op inside a validated batch is condemned; here the caller cannot prove
    # control of the slot's Root at all, which is an authorization failure of
    # the whole request.
    try:
        verify_escrow_signature(
            workspace_id,
            body.version,
            blob,
            root_sig,
            stored.root_pk if stored is not None else root_pk,
        )
    except EscrowSignatureError as exc:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"code": "bad_escrow_signature"},
        ) from exc

    # Both branches below are read-then-write, so both need the write itself to
    # be conditional — two devices enrolling at once, or two re-wraps of the same
    # version, otherwise resolve as a 500 and as a silently lost blob.
    if stored is None:
        # Deliberately the same code as the regression case: `stored_version: 0`
        # reads unambiguously as "no record exists; create must be v1", and a
        # client gets one version-rule code to handle rather than two.
        if body.version != FIRST_ESCROW_VERSION:
            raise _escrow_version_conflict(NO_ESCROW_STORED_VERSION)
        now = datetime.now(UTC)
        db.add(
            RecoveryEscrow(
                workspace_id=workspace_id,
                user_id=current_user.id,
                version=body.version,
                blob=blob,
                root_sig=root_sig,
                root_pk=root_pk,
                created_at=now,
                updated_at=now,
            )
        )
        try:
            await db.commit()
        except IntegrityError as exc:
            # The slot was created between the read above and this insert. The
            # loser learns "already written" rather than a 500 — which is exactly
            # what the enrolment ceremony's blind second-slot write reads as.
            await db.rollback()
            raise _escrow_version_conflict(NO_ESCROW_STORED_VERSION) from exc
        return _escrow_out(version=body.version, blob=blob, root_sig=root_sig, root_pk=root_pk)

    if body.version <= stored.version:
        raise _escrow_version_conflict(stored.version)
    # The version this update was decided against is part of its WHERE clause, so
    # two concurrent re-wraps at v+1 cannot both land: the loser matches no row
    # and is told what the slot now holds instead of overwriting the winner.
    observed_version = stored.version
    root_pk_in_slot = stored.root_pk
    updated = cast(
        CursorResult[Any],
        await db.execute(
            update(RecoveryEscrow)
            .where(
                RecoveryEscrow.workspace_id == workspace_id,
                RecoveryEscrow.user_id == current_user.id,
                RecoveryEscrow.version == observed_version,
            )
            .values(
                version=body.version,
                blob=blob,
                root_sig=root_sig,
                updated_at=datetime.now(UTC),
            )
        ),
    )
    if updated.rowcount != 1:
        await db.rollback()
        raise _escrow_version_conflict(observed_version)
    await db.commit()
    return _escrow_out(version=body.version, blob=blob, root_sig=root_sig, root_pk=root_pk_in_slot)


@router.get("/w/{workspace_id}/recovery", response_model=RecoveryEscrowResponse)
async def get_recovery_escrow(
    workspace_id: uuid.UUID,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
    redis: Redis = Depends(get_redis),
) -> RecoveryEscrowResponse:
    """Return the escrow verbatim.  Rate-limited and audited.

    The route takes no body and no parameters: nothing passphrase-derived ever
    reaches the server, so there is nothing for it to accept.
    """
    _require_derivable_workspace(workspace_id, current_user.id)
    # Existence before the quota. The limit bounds *bytes leaving the slot*, so a
    # slot that holds nothing must not be able to spend it: twenty requests
    # against an unenrolled account would otherwise lock its real recovery fetch
    # out for a day — the one fetch that matters, refused because of attempts
    # that returned nothing.
    stored = await db.get(RecoveryEscrow, (workspace_id, current_user.id))
    if stored is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "no_recovery_escrow"},
        )
    if await count_recovery_fetch(redis, current_user.id) > RECOVERY_FETCH_DAILY_LIMIT:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail={
                "code": "escrow_fetch_rate_limited",
                "retry_after_seconds": await recovery_fetch_retry_after_seconds(
                    redis, current_user.id
                ),
            },
        )
    # Audited before the bytes leave: a silent read is what an escrow attack
    # needs, so every read that serves the slot is a row the User can be shown.
    db.add(
        RecoveryEscrowFetch(
            workspace_id=workspace_id,
            user_id=current_user.id,
            fetched_at=datetime.now(UTC),
        )
    )
    await db.commit()
    return _escrow_out(
        version=stored.version,
        blob=stored.blob,
        root_sig=stored.root_sig,
        root_pk=stored.root_pk,
    )


def _escrow_version_conflict(stored_version: int) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail={"code": "escrow_version_regression", "stored_version": stored_version},
    )


def _escrow_out(
    *, version: int, blob: bytes, root_sig: bytes, root_pk: bytes
) -> RecoveryEscrowResponse:
    """The record as the caller gets it back, built from the bytes just stored.

    Values rather than the ORM object: the update path writes through a
    version-guarded ``UPDATE``, so the loaded instance still carries the version
    that update was decided against.
    """
    return RecoveryEscrowResponse(
        version=version,
        blob_b64=base64.b64encode(blob).decode("ascii"),
        root_sig_b64=base64.b64encode(root_sig).decode("ascii"),
        root_pk_b64=base64.b64encode(root_pk).decode("ascii"),
    )


# ── Op log ────────────────────────────────────────────────────────────────────


@router.post("/w/{workspace_id}/ops", response_model=PostOpsResponse)
async def post_ops(
    workspace_id: uuid.UUID,
    body: PostOpsRequest,
    db: AsyncSession = Depends(get_db),
    current_member: Member = Depends(get_current_member),
    hub: SignalHub = Depends(get_signal_hub),
) -> PostOpsResponse:
    _require_derivable_workspace(workspace_id, current_member.user_id)
    if len(body.ops) > MAX_OPS_PER_BATCH:
        raise HTTPException(
            status_code=status.HTTP_413_CONTENT_TOO_LARGE,
            detail={"code": "batch_too_large", "max_ops": MAX_OPS_PER_BATCH},
        )

    parsed: list[tuple[bytes, OpHeader]] = []
    for index, encoded in enumerate(body.ops):
        envelope = _decode_base64(encoded, "malformed_base64", index=index)
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
            raise _unprocessable(exc.reason, index=index) from exc
        if header.workspace_id != workspace_id:
            # The index columns are a pure index cross-checked against the
            # envelope bytes, never trusted over them (review F6).
            raise _unprocessable("workspace_mismatch", index=index)
        if header.author_member_id != current_member.member_id:
            # F10, in one comparison and no crypto: a token speaks for exactly
            # one Member, and that Member is the only author it can post as.
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail={"code": "author_member_mismatch", "index": index},
            )
        parsed.append((envelope, header))

    if not parsed:
        return PostOpsResponse(results=[])

    # Control verification and per-op authorization run before the chain-conflict
    # check below, so a mispositioned register yields `member_register_not_first`
    # and never the 409 — a client's chain verdict only ever sees registers
    # already at seq 1.
    admissions = await _verify_and_authorize(db, workspace_id, current_member, parsed)

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
            # The code alone: a constraint violation names no batch index, and a
            # guessed ``expected_author_seq`` here would be read as a rollback
            # verdict on the client.  Omitting it says "no verdict" exactly.
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={"code": "author_chain_conflict"},
            ) from exc

    # Materialisation runs *after* the append because every index row it writes is
    # anchored to a transport seq, and a seq does not exist until the op is
    # stored.  That is not an implementation accident: the authorization verdict
    # is positional against `granted_seq`/`revoked_by_seq`, so those numbers have
    # to be the real ones.
    revoked_members = await _materialise_control(db, workspace_id, admissions, results)
    try:
        await db.commit()
    except IntegrityError as exc:
        # The retried block above covers the *ops* constraint; this covers the
        # index rows materialisation writes, and the one of those a legal race can
        # collide on is ``workspaces``.  Two Root-holding devices may both observe
        # an empty control log and both author a genesis: ``_verify_genesis`` reads
        # ``workspace_exists`` from this transaction's snapshot, so under a real
        # concurrent interleave both see False and both reach here.  Exactly one
        # primary key survives, and the loser must learn the same deterministic
        # 409 the sequential case gives it — never a 500, which says nothing about
        # what to do next.
        await db.rollback()
        raise await _resolve_commit_conflict(db, workspace_id, admissions, exc) from exc

    for member_id in revoked_members:
        # Two halves of one revocation, both after the commit.  The refresh
        # tokens die so nothing can authenticate a *new* socket or POST, and the
        # live sockets close so an already-authenticated subscriber stops
        # learning that activity exists in the Workspace — a socket is
        # authenticated once, at the handshake, and never re-checked.
        await revoke_member_transport(db, member_id)
        hub.revoke(workspace_id, member_id)

    if any(not result.duplicate for result in results):
        # After the commit, never before: a subscriber woken by a poke pulls
        # immediately, and pulling against an uncommitted transaction would
        # return nothing and burn the poke.  A pure-duplicate replay is not news.
        hub.notify(workspace_id)
    return PostOpsResponse(results=results)


async def _resolve_commit_conflict(
    db: AsyncSession,
    workspace_id: uuid.UUID,
    admissions: list[_ControlAdmission],
    exc: IntegrityError,
) -> BaseException:
    """Name the constraint a rolled-back commit lost, or hand the failure back.

    Resolved by *re-reading committed state* rather than by matching a driver's
    error text: the batch carried a genesis and the Workspace now exists, so
    somebody else founded it — which is exactly ``genesis_not_first``, and the
    client's move is the one the sequential refusal already teaches it.

    Anything else propagates unchanged.  Relabelling an unrecognised constraint
    violation as a lost genesis race would send a client down a recovery path for
    a problem it does not have, and hide a real bug behind a benign code.
    """
    genesis = next(
        (
            admission
            for admission in admissions
            if admission.control_type == CONTROL_TYPE_WORKSPACE_GENESIS
        ),
        None,
    )
    if genesis is None:
        return exc
    if await db.get(Workspace, workspace_id) is None:
        return exc
    return _conflict("genesis_not_first", index=genesis.index)


@dataclass(slots=True)
class _ControlAdmission:
    """One verified control op, and what it will materialise once it has a seq.

    Verification and materialisation are deliberately two passes: the first can
    refuse the whole batch, the second needs transport seqs that only exist after
    the append.  Carrying the parsed certificate between them means the bytes are
    verified exactly once.
    """

    index: int
    control_type: str
    #: Populated by ``member_register`` and by the registration a genesis embeds.
    registration: RegistrationCertificate | None = None
    grant: GrantCertificate | None = None
    revoke: RevokeCertificate | None = None


async def _verify_and_authorize(
    db: AsyncSession,
    workspace_id: uuid.UUID,
    current_member: Member,
    parsed: list[tuple[bytes, OpHeader]],
) -> list[_ControlAdmission]:
    """Verify every control op and authorize every op, in arrival order.

    The walk is ordered on purpose: the server materialises a batch's control ops
    in the order they arrive, so a Grant authored at index 1 counts for a content
    op at index 2 of the same POST.  That is "validity at the log position of
    signing" — the same rule the client applies to its own derived view.

    Control-op rejections are a 422 carrying the batch ``index``: one fail-closed
    family, so #554 opens a control type up by adding a case rather than by
    loosening the failure mode.  Authorization rejections are a 403, matching
    ``author_member_mismatch`` — the caller's credential is the thing at fault.
    """
    grants = await _grant_index(db, workspace_id)
    workspace_exists = await db.get(Workspace, workspace_id) is not None
    # Which of this batch's ops the log already holds.  A replay must not read as
    # a *reuse* of the grant id it carries: the id belongs to the op that first
    # asserted it, and re-posting that same op asserts nothing new.
    replayed_op_ids = set(
        (
            await db.execute(
                select(Op.op_id).where(
                    Op.workspace_id == workspace_id,
                    Op.author_member_id == current_member.member_id,
                    Op.op_id.in_({header.op_id for _, header in parsed}),
                )
            )
        )
        .scalars()
        .all()
    )
    escrow = await db.get(RecoveryEscrow, (workspace_id, current_member.user_id))
    # No escrow means no Root the server can check against, so nothing can be
    # Root-signed: fail closed rather than materialise on trust.  The escrow slot
    # of *this* Workspace, which is why the ceremony writes both slots.
    root_pk = escrow.root_pk if escrow is not None else b""
    is_preferences = workspace_id == user_preferences_workspace_id(current_member.user_id)
    # Member kinds this batch certifies but has not yet materialised — the
    # enrolment batch grants itself in the same POST that registers it.
    staged_kinds: dict[uuid.UUID, str] = {}

    admissions: list[_ControlAdmission] = []
    for index, (envelope, header) in enumerate(parsed):
        if header.op_class != OP_CLASS_CONTROL:
            # Content today; suggestion and compaction when #557/#555 widen
            # SERVED_OP_CLASSES.  Both need a Workspace somebody signed into
            # existence and a live Grant whose role the matrix admits.
            if not workspace_exists:
                raise _conflict("workspace_not_created", index=index)
            _require_role(grants, current_member.member_id, header.op_class, index)
            continue

        payload = _decode_control_payload(envelope, index)
        try:
            payload.require_chain_link_shape()
        except ControlPayloadError as exc:
            raise _unprocessable(exc.reason, index=index) from exc

        if payload.control_type == CONTROL_TYPE_WORKSPACE_GENESIS:
            genesis = _verify_genesis(
                payload,
                header,
                index=index,
                workspace_id=workspace_id,
                current_member=current_member,
                root_pk=root_pk,
                workspace_exists=workspace_exists,
            )
            founder = genesis.as_registration()
            workspace_exists = True
            staged_kinds[founder.member_id] = founder.member_kind
            admissions.append(
                _ControlAdmission(
                    index=index,
                    control_type=payload.control_type,
                    registration=founder,
                )
            )
            continue

        if not workspace_exists:
            raise _conflict("workspace_not_created", index=index)

        # A **root-signed** control payload lands regardless of Grants: that is
        # how an ungranted device's register-plus-grant batch gets in at all, and
        # it is safe because Root's signature is the strongest authority there is.
        # Anything else needs the live owner Grant the matrix demands.
        if not payload.is_root_signed:
            _require_role(grants, current_member.member_id, OP_CLASS_CONTROL, index)

        if payload.control_type == CONTROL_TYPE_MEMBER_REGISTER:
            registration = _verify_member_register(
                payload,
                header,
                index=index,
                workspace_id=workspace_id,
                current_member=current_member,
                root_pk=root_pk,
            )
            staged_kinds[registration.member_id] = registration.member_kind
            admissions.append(
                _ControlAdmission(
                    index=index,
                    control_type=payload.control_type,
                    registration=registration,
                )
            )
        elif payload.control_type == CONTROL_TYPE_GRANT:
            grant = await _verify_grant(
                db,
                payload,
                header,
                index=index,
                workspace_id=workspace_id,
                current_member=current_member,
                root_pk=root_pk,
                grants=grants,
                staged_kinds=staged_kinds,
                is_preferences=is_preferences,
                is_replay=header.op_id in replayed_op_ids,
            )
            grants.add(grant.grant_id, grant.member_id, grant.role)
            admissions.append(
                _ControlAdmission(index=index, control_type=payload.control_type, grant=grant)
            )
        elif payload.control_type == CONTROL_TYPE_REVOKE:
            revoke = _verify_revoke(
                payload,
                header,
                index=index,
                workspace_id=workspace_id,
                current_member=current_member,
                root_pk=root_pk,
                grants=grants,
                is_replay=header.op_id in replayed_op_ids,
            )
            grants.revoke(revoke.grant_id)
            admissions.append(
                _ControlAdmission(index=index, control_type=payload.control_type, revoke=revoke)
            )
        else:  # pragma: no cover — ``require_served_type`` already refused it
            raise _unprocessable("unsupported_control_type", index=index)

    return admissions


def _require_role(grants: _GrantIndex, member_id: uuid.UUID, op_class: int, index: int) -> None:
    """The ``(grant.role, header.op_class)`` matrix, content-blind as ever."""
    roles = grants.live_roles(member_id)
    if not roles:
        # ``revoked`` separates "never granted" from "granted and taken away".
        # The refusal is the same either way; the distinction is what a client
        # surfaces to a user whose device has been removed.
        if grants.has_any_grant(member_id):
            raise _forbidden("no_live_grant", index=index, revoked=True)
        raise _forbidden("no_live_grant", index=index)
    if not roles & ROLE_OP_CLASS_MATRIX.get(op_class, frozenset()):
        raise _forbidden(
            "role_forbids_op_class", index=index, op_class=op_class, roles=sorted(roles)
        )


def _decode_control_payload(envelope: bytes, index: int) -> ControlPayload:
    _header_bytes, body, _signature = split_envelope(envelope)
    try:
        payload_bytes = parse_body(body)
    except EnvelopeError as exc:
        # A body the framing cannot even delimit never reaches control parsing —
        # same fail-closed family, its own code.
        raise _unprocessable(exc.reason, index=index) from exc
    try:
        payload = ControlPayload.decode(payload_bytes)
        payload.require_served_type()
    except UnsupportedControlTypeError as exc:
        raise _unprocessable(exc.reason, index=index, type=exc.observed_type) from exc
    except ControlPayloadError as exc:
        raise _unprocessable(exc.reason, index=index) from exc
    return payload


def _verify_genesis(
    payload: ControlPayload,
    header: OpHeader,
    *,
    index: int,
    workspace_id: uuid.UUID,
    current_member: Member,
    root_pk: bytes,
    workspace_exists: bool,
) -> GenesisCertificate:
    """Genesis is the Workspace's first control op, and its author's first op.

    It carries the founding Member's registration because it has to: the
    envelope's author key is unknowable before the certificate parses, and there
    is no earlier op to learn it from (ADR-0031).  So the founding Device authors
    no separate ``member_register`` — genesis *is* its registration.
    """
    if index != 0 or workspace_exists:
        # First in the log and first in the batch.  A second genesis is not a
        # fork for the server to resolve: it holds no control chain, so it
        # refuses and leaves the tie-break to the clients that do.
        raise _conflict("genesis_not_first", index=index)
    if workspace_id not in derivable_workspace_ids(current_member.user_id):
        # The v1 anti-junk-workspace rule, restated at the one place a Workspace
        # comes into being.  Real user-created Workspaces lift it.
        raise _forbidden("workspace_not_derivable", index=index)
    if header.author_seq != 1:
        # D1's generalisation of #548's rule: an author's first op must be the
        # control op that registers it — a ``member_register``, or the genesis
        # that embeds one.
        raise _unprocessable("member_register_not_first", index=index, author_seq=header.author_seq)
    if payload.prev_control_hash != ZERO_PREV_CONTROL_HASH:
        raise _unprocessable("control_chain_break", index=index)
    try:
        verify_genesis_certificate(payload.cert_bytes, payload.root_sig, root_pk)
        certificate = payload.genesis_certificate()
    except ControlPayloadError as exc:
        raise _unprocessable(exc.reason, index=index) from exc
    if certificate.workspace_id != workspace_id:
        raise _unprocessable("cert_workspace_mismatch", index=index)
    if certificate.root_pk != root_pk:
        # The Root inside the signed genesis must be the Root the slot holds:
        # that cross-check is why it is in there at all.
        raise _unprocessable("cert_root_pk_mismatch", index=index)
    if certificate.founder.member_id != header.author_member_id:
        raise _unprocessable("cert_member_mismatch", index=index)
    if certificate.founder.sign_pk != current_member.sign_pk:
        raise _unprocessable("cert_key_mismatch", index=index)
    return certificate


def _verify_member_register(
    payload: ControlPayload,
    header: OpHeader,
    *,
    index: int,
    workspace_id: uuid.UUID,
    current_member: Member,
    root_pk: bytes,
) -> RegistrationCertificate:
    if header.author_seq != 1:
        # A register is its author's *first* op.  The chain rule only guarantees
        # that an author's first op is seq 1; it does not guarantee that seq 1 is
        # the register.
        raise _unprocessable("member_register_not_first", index=index, author_seq=header.author_seq)
    try:
        verify_registration_certificate(payload.cert_bytes, payload.root_sig, root_pk)
        certificate = payload.certificate()
    except ControlPayloadError as exc:
        raise _unprocessable(exc.reason, index=index) from exc
    if certificate.workspace_id != workspace_id:
        raise _unprocessable("cert_workspace_mismatch", index=index)
    if certificate.member_id != header.author_member_id:
        raise _unprocessable("cert_member_mismatch", index=index)
    if certificate.sign_pk != current_member.sign_pk:
        raise _unprocessable("cert_key_mismatch", index=index)
    return certificate


async def _verify_grant(
    db: AsyncSession,
    payload: ControlPayload,
    header: OpHeader,
    *,
    index: int,
    workspace_id: uuid.UUID,
    current_member: Member,
    root_pk: bytes,
    grants: _GrantIndex,
    staged_kinds: dict[uuid.UUID, str],
    is_preferences: bool,
    is_replay: bool,
) -> GrantCertificate:
    """Verify one Grant, including both authority ceilings.

    An ``owner`` Grant may only be minted with ``granter == "root"``, exactly as
    it may only be revoked with ``revoker == "root"``.  The symmetry is the point
    (ADR-0031): an owner-mints-owner rule would let a compromised device create
    an attacker-owner cheaply while removing one still cost the passphrase, and
    that asymmetry favours the attacker.
    """
    try:
        certificate = payload.grant_certificate()
    except ControlPayloadError as exc:
        raise _unprocessable(exc.reason, index=index) from exc
    if certificate.workspace_id != workspace_id:
        raise _unprocessable("cert_workspace_mismatch", index=index)
    if certificate.granter != payload.authority:
        # The signed certificate names its own granter; the payload's ``granter``
        # field only says which key to check it against.  A disagreement between
        # them is a forgery attempt, not a spelling.
        raise _unprocessable("cert_granter_mismatch", index=index)
    granter_pk = _authority_public_key(
        payload.authority, header, index=index, root_pk=root_pk, current_member=current_member
    )
    try:
        verify_grant_certificate(payload.cert_bytes, payload.signature, granter_pk)
    except ControlPayloadError as exc:
        raise _unprocessable(exc.reason, index=index) from exc
    if certificate.role == ROLE_OWNER and payload.authority != GRANTER_ROOT:
        raise _unprocessable("owner_grant_requires_root", index=index)

    grantee = await db.get(Member, certificate.member_id)
    if grantee is None or grantee.user_id != current_member.user_id:
        raise _unprocessable("unknown_grantee", index=index)
    if certificate.member_id in staged_kinds:
        member_kind = staged_kinds[certificate.member_id]
    elif grantee.chained_at is not None:
        # Rows chained before #549 carry no ``member_kind`` and were all Devices,
        # so ``device`` here is exact rather than a guess.
        member_kind = grantee.member_kind or MEMBER_KIND_DEVICE
    else:
        # Fail closed on an unmaterialised grantee: a Grant is never held as a
        # dangling forward reference, and the server's bar is the same one the
        # client's chain-gated directory applies.
        raise _unprocessable("unknown_grantee", index=index)
    if is_preferences and member_kind != MEMBER_KIND_DEVICE:
        # The server-side half of "every Device, no Service ever".  The boundary
        # is structural, which is why preferences are a Workspace of their own:
        # a preference can never leak through an AI grant.
        raise _unprocessable("service_grant_forbidden", index=index)
    if not is_replay and grants.state(certificate.grant_id) is not None:
        # A *different* op reusing a grant id — refused rather than allowed to
        # collide on the index's primary key.  A replay of the op that minted the
        # id in the first place is excluded, because it asserts nothing new: the
        # id belongs to that op, and re-posting it is the dedupe path's business.
        raise _conflict("grant_id_already_used", index=index)
    return certificate


def _verify_revoke(
    payload: ControlPayload,
    header: OpHeader,
    *,
    index: int,
    workspace_id: uuid.UUID,
    current_member: Member,
    root_pk: bytes,
    grants: _GrantIndex,
    is_replay: bool,
) -> RevokeCertificate:
    """Revocation is **grant-granular**: a Revoke names one ``grant_id``.

    Revoking a granter does not cascade (F14c).  Nothing re-evaluates a Grant
    that was valid at the position it was signed at, so a fact once valid stands
    — which is what makes late arrivals honest rather than retroactively refused.
    """
    try:
        certificate = payload.revoke_certificate()
    except ControlPayloadError as exc:
        raise _unprocessable(exc.reason, index=index) from exc
    if certificate.workspace_id != workspace_id:
        raise _unprocessable("cert_workspace_mismatch", index=index)
    if certificate.revoker != payload.authority:
        raise _unprocessable("cert_granter_mismatch", index=index)
    revoker_pk = _authority_public_key(
        payload.authority, header, index=index, root_pk=root_pk, current_member=current_member
    )
    try:
        verify_revoke_certificate(payload.cert_bytes, payload.signature, revoker_pk)
    except ControlPayloadError as exc:
        raise _unprocessable(exc.reason, index=index) from exc
    target = grants.state(certificate.grant_id)
    if target is None:
        # A Revoke names a ``grant_id``, so a missing target is a missing *Grant* —
        # distinct from ``unknown_grantee``, which a Grant earns by naming a member
        # nobody registered.  Conflating them would leave a client unable to tell a
        # failed revocation from an invalid grantee.
        raise _unprocessable("unknown_grant", index=index)
    if target.revoked and not is_replay:
        # The revocation boundary is immutable once stamped.  The authorization
        # verdict is positional — ``granted_seq < S < revoked_by_seq`` — so moving
        # ``revoked_by_seq`` forward would *widen* the window an already-revoked
        # Grant covers.  Refused rather than silently ignored, so the client learns
        # the Grant is already gone instead of believing it just revoked it.
        #
        # A verbatim replay is exempt, on the same reasoning as ``_verify_grant``'s:
        # re-posting the op that *did* the revoking asserts nothing new, and it must
        # come back as the idempotent duplicate a retried POST expects rather than as
        # a refusal.  Materialisation skips duplicates, so the boundary stays put.
        raise _unprocessable("already_revoked", index=index)
    if target.role == ROLE_OWNER and payload.authority != GRANTER_ROOT:
        raise _unprocessable("owner_revoke_requires_root", index=index)
    return certificate


def _authority_public_key(
    authority: str,
    header: OpHeader,
    *,
    index: int,
    root_pk: bytes,
    current_member: Member,
) -> bytes:
    """Whose key must have signed this grant or revoke certificate.

    Root, or the authoring Member itself — **authority does not travel by
    courier**.  The owner-Grant requirement on the author was already applied by
    the matrix before this is reached, so all that is left is to insist the
    claimed authority *is* the author.
    """
    if authority == GRANTER_ROOT:
        return root_pk
    if str(header.author_member_id) != authority:
        raise _unprocessable("cert_granter_mismatch", index=index)
    return current_member.sign_pk


async def _materialise_control(
    db: AsyncSession,
    workspace_id: uuid.UUID,
    admissions: list[_ControlAdmission],
    results: list[OpResult],
) -> list[uuid.UUID]:
    """Write the index rows the batch's control ops stand for.

    Returns the Members that lost their last live Grant, whose transport
    credentials and live sockets the caller then closes.
    """
    staged_grants: dict[uuid.UUID, Grant] = {}
    revoked_from: set[uuid.UUID] = set()
    now = datetime.now(UTC)
    for admission in admissions:
        result = results[admission.index]
        if result.duplicate:
            # A verbatim replay: the index already holds what this op stands for,
            # and re-materialising it would move ``granted_seq`` off the op that
            # actually created the Grant.
            continue
        registration = admission.registration
        if registration is not None:
            member = await db.get(Member, registration.member_id)
            if member is not None:
                member.chained_at = member.chained_at or now
                member.member_kind = registration.member_kind
        if admission.control_type == CONTROL_TYPE_WORKSPACE_GENESIS:
            db.add(Workspace(workspace_id=workspace_id, genesis_seq=result.seq, created_at=now))
        elif admission.grant is not None:
            granted = Grant(
                workspace_id=workspace_id,
                grant_id=admission.grant.grant_id,
                member_id=admission.grant.member_id,
                role=admission.grant.role,
                granter=admission.grant.granter,
                granted_seq=result.seq,
                created_at=now,
            )
            db.add(granted)
            staged_grants[granted.grant_id] = granted
        elif admission.revoke is not None:
            target = staged_grants.get(admission.revoke.grant_id) or await db.get(
                Grant, (workspace_id, admission.revoke.grant_id)
            )
            if target is None:  # pragma: no cover — verification proved it exists
                continue
            if target.revoked_by_seq is not None:
                # Belt to ``_verify_revoke``'s braces: the stamp is written once and
                # never moved, because the verdict window it closes is positional.
                continue
            target.revoked_by_seq = result.seq
            revoked_from.add(target.member_id)

    if not revoked_from:
        return []
    # One query, after the writes: the select autoflushes, so it sees this
    # batch's own grants and revocations rather than a stale snapshot.
    still_live = set(
        (
            await db.execute(
                select(Grant.member_id).where(
                    Grant.workspace_id == workspace_id,
                    Grant.member_id.in_(revoked_from),
                    Grant.revoked_by_seq.is_(None),
                )
            )
        )
        .scalars()
        .all()
    )
    return [member_id for member_id in revoked_from if member_id not in still_live]


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
            #
            # ``expected_author_seq`` is the load-bearing field, not a courtesy:
            # a single-writer client compares it against the head this server has
            # already acknowledged to tell an ordinary conflict from a server that
            # rolled its writes back.  The race-retry path below cannot attribute
            # the conflict to one op and so sends the code alone, which the client
            # reads as "no verdict".
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "code": "author_chain_conflict",
                    "index": index,
                    "author_seq": header.author_seq,
                    "expected_author_seq": expected_author_seq,
                },
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
    current_member: Member = Depends(get_current_member),
) -> PullOpsResponse:
    """``since`` is a pure client parameter — no cursor is persisted (review F17).

    A **pre-genesis pull returns an empty page**, never an error: this is the
    observation the enrolment ceremony branches on when it decides whether to
    author a genesis, and it runs while the device holds a member credential and
    no Grant at all.  ``workspace_not_created`` is a POST-path refusal only.
    """
    _require_derivable_workspace(workspace_id, current_member.user_id)
    await _refuse_if_revoked(db, workspace_id, current_member)
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

    # The same member-scoped resolution the ops routes use, and for the same
    # reason: a socket that accepted a plain user token would be the weak door
    # into a Workspace whose HTTP surface refuses one.
    try:
        current_member = await resolve_member_token(token, db)
    except HTTPException:
        await _close_quietly(websocket, SIGNAL_CLOSE_UNAUTHENTICATED)
        return
    try:
        _require_derivable_workspace(workspace_id, current_member.user_id)
        # The handshake is held to the member-GET bar: an unrevoked member token
        # is enough, so a pre-grant device can subscribe during enrolment, and a
        # revoked one is refused at the door as well as having its live sockets
        # closed under it.
        await _refuse_if_revoked(db, workspace_id, current_member)
    except HTTPException:
        await _close_quietly(websocket, SIGNAL_CLOSE_FORBIDDEN)
        return
    member_id = current_member.member_id

    # The handshake is the only part of this endpoint that may hold a database
    # session.  ``Depends(get_db)`` checks one out for the lifetime of the
    # endpoint, and here that lifetime is the *connection's* — so left open it
    # parks a pooled connection idle-in-transaction for as long as the
    # subscriber stays connected, and roughly fifteen subscribers (pool 5 +
    # overflow 10) starve every HTTP request in the process.
    #
    # Constraint for anything added below this line: the session must not
    # outlive the handshake, and the signal pump must never touch the database.
    # ``current_member`` is deliberately not read again — the authorization
    # decision it feeds is already made above, and it is a detached ORM instance
    # the moment this session closes.  Its ``member_id`` was copied out above for
    # the subscription, which needs a plain uuid and not a live ORM row.
    await db.close()

    # Member-aware: a revocation has to be able to close *this* Member's sockets,
    # and the id is the only thing the hub knows about a subscriber beyond its
    # Workspace.
    with hub.subscribe(workspace_id, member_id) as subscription:
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
    """One loop, two frame kinds and one close — nothing else, ever.

    The keepalive is the *timeout branch* of the same wait that delivers pokes,
    so it fires only in the absence of news.  That makes it the exact complement
    of what a poke reveals ("no activity right now"), which is why an
    application-level heartbeat adds nothing to the leak surface.

    The third branch is revocation.  A socket is authenticated once, at the
    handshake, and never re-checked, so losing the last live Grant has to reach
    an *already open* socket — otherwise a revoked subscriber keeps learning that
    activity exists in the Workspace.  It closes with ``4403``, the same code the
    handshake would have refused it with, so the client's reconnect ladder needs
    no new branch: it already treats 4403 as "do not retry blindly".
    """
    while not reader.done():
        waiter = asyncio.create_task(subscription.wait())
        revoked = asyncio.create_task(subscription.wait_revoked())
        try:
            done, _ = await asyncio.wait(
                {waiter, revoked, reader},
                timeout=settings.signal_keepalive_interval_seconds,
                return_when=asyncio.FIRST_COMPLETED,
            )
        finally:
            for task in (waiter, revoked):
                if not task.done():
                    task.cancel()
        if revoked in done:
            # Checked before the reader: a revoked subscriber should learn *why*
            # its socket ended, and a bare disconnect says nothing.
            await _close_quietly(websocket, SIGNAL_CLOSE_FORBIDDEN)
            return
        if reader in done:
            return
        if waiter in done:
            # Cleared before the send, so an append racing this line pokes again
            # rather than being swallowed by the frame already on its way.
            subscription.clear()
            await websocket.send_text("")
        else:
            await websocket.send_text(KEEPALIVE_FRAME)
