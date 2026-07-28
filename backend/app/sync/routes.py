"""The Minimal Sync Server's HTTP surface.

Content ops stay opaque: the server reads the 158-byte header and never a body.
**Control ops are the deliberate exception** — ``op_class=2`` payloads are
unencrypted precisely so the server can check that a Member was registered by
Root before it materialises the membership (ADR-0028, review F2).  That is the
only body-reading path here, and it is fail-closed at every step.

Transport auth is member-scoped: the sync data routes (``GET``/``POST
/w/{w}/ops`` and ``GET /w/{w}/members``) require a token issued by the
proof-of-possession exchange in ``app.sync.member_auth``, and every posted op
must name that same member as its author.  ``POST /members`` and the recovery
escrow routes take the User credential instead, because they are what a Device
uses *before* it has a member credential.

Authorization on the Workspace itself is still the stub #549 replaces: a User
has exactly one implicit Workspace derived from the user id, and the Grants
index that will decide the question does not exist yet.

**Error details.** Every rejection this module raises carries a structured
detail — ``{"code": <snake_case>, ...}`` — and a per-op rejection on
``POST /w/{w}/ops`` additionally carries the zero-based batch ``index`` of the
offending op, so a client can point at the op rather than parsing prose.
"""

from __future__ import annotations

import base64
import binascii
import uuid
from datetime import UTC, datetime
from typing import Any, cast

from fastapi import APIRouter, Depends, HTTPException, Query, Response, status
from redis.asyncio import Redis
from sqlalchemy import CursorResult, func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_member, get_current_user
from app.auth.models import RefreshToken, User
from app.auth.schemas import RefreshRequest, Token
from app.auth.tokens import create_access_token, create_refresh_token, hash_refresh_token
from app.config import settings
from app.database import get_db
from app.redis import get_redis
from app.sync.control_payload import (
    KEX_PUBLIC_KEY_BYTES,
    ControlPayload,
    ControlPayloadError,
    UnsupportedControlTypeError,
    verify_registration_certificate,
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
    NO_ESCROW_STORED_VERSION,
    RECOVERY_FETCH_DAILY_LIMIT,
    ROOT_PUBLIC_KEY_BYTES,
    ROOT_SIGNATURE_BYTES,
    EscrowSignatureError,
    count_recovery_fetch,
    recovery_fetch_retry_after_seconds,
    verify_escrow_signature,
)
from app.sync.ids import implicit_workspace_id
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
from app.sync.models import Member, Op, RecoveryEscrow, RecoveryEscrowFetch
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

router = APIRouter()

# not configurable: transport paging, sized for the harness and for a first
# real device bootstrap.  Tune here if a fleet ever needs it, not per request.
DEFAULT_OPS_PAGE_LIMIT = 500
MAX_OPS_PAGE_LIMIT = 1000
#: Guards the single-transaction batch from an unbounded request body.
MAX_OPS_PER_BATCH = 1000


def _authorize_workspace(workspace_id: uuid.UUID, user_id: str) -> None:
    """Stub Grant check: a User reaches exactly their own implicit Workspace."""
    if workspace_id != implicit_workspace_id(user_id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={"code": "no_workspace_grant"},
        )


def _unprocessable(code: str, **fields: Any) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        detail={"code": code, **fields},
    )


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
    _authorize_workspace(workspace_id, current_member.user_id)
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

    nonce = _decode_base64(body.nonce, "bad_member_challenge")
    if len(nonce) != MEMBER_CHALLENGE_NONCE_BYTES:
        raise unauthorized
    signature = _decode_base64(body.signature, "bad_member_challenge")

    # GETDEL first: a challenge is spent by the attempt, win or lose, so a
    # signature-guessing loop needs a fresh round-trip for every guess.
    stored = await consume_member_challenge(redis, body.nonce)
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
    """
    _authorize_workspace(workspace_id, current_user.id)
    blob = _decode_base64(body.blob_b64, "malformed_escrow_blob")
    root_sig = _decode_base64(body.root_sig_b64, "malformed_escrow_signature")
    root_pk = _decode_base64(body.root_pk_b64, "malformed_root_pk")
    if len(root_sig) != ROOT_SIGNATURE_BYTES:
        raise _unprocessable("malformed_escrow_signature", expected_bytes=ROOT_SIGNATURE_BYTES)
    if len(root_pk) != ROOT_PUBLIC_KEY_BYTES:
        raise _unprocessable("malformed_root_pk", expected_bytes=ROOT_PUBLIC_KEY_BYTES)
    if body.version < FIRST_ESCROW_VERSION:
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

    if stored is None:
        # Deliberately the same code as the regression case: `stored_version: 0`
        # reads unambiguously as "no record exists; create must be v1", and a
        # client gets one version-rule code to handle rather than two.
        if body.version != FIRST_ESCROW_VERSION:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "code": "escrow_version_regression",
                    "stored_version": NO_ESCROW_STORED_VERSION,
                },
            )
        now = datetime.now(UTC)
        stored = RecoveryEscrow(
            workspace_id=workspace_id,
            user_id=current_user.id,
            version=body.version,
            blob=blob,
            root_sig=root_sig,
            root_pk=root_pk,
            created_at=now,
            updated_at=now,
        )
        db.add(stored)
    else:
        if body.version <= stored.version:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={"code": "escrow_version_regression", "stored_version": stored.version},
            )
        stored.version = body.version
        stored.blob = blob
        stored.root_sig = root_sig
        stored.updated_at = datetime.now(UTC)

    await db.commit()
    return _escrow_out(stored)


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
    _authorize_workspace(workspace_id, current_user.id)
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

    stored = await db.get(RecoveryEscrow, (workspace_id, current_user.id))
    if stored is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"code": "no_recovery_escrow"},
        )
    # Audited before the bytes leave: a silent read is what an escrow attack
    # needs, so every read is a row the User can be shown.
    db.add(
        RecoveryEscrowFetch(
            workspace_id=workspace_id,
            user_id=current_user.id,
            fetched_at=datetime.now(UTC),
        )
    )
    await db.commit()
    return _escrow_out(stored)


def _escrow_out(record: RecoveryEscrow) -> RecoveryEscrowResponse:
    return RecoveryEscrowResponse(
        version=record.version,
        blob_b64=base64.b64encode(record.blob).decode("ascii"),
        root_sig_b64=base64.b64encode(record.root_sig).decode("ascii"),
        root_pk_b64=base64.b64encode(record.root_pk).decode("ascii"),
    )


# ── Op log ────────────────────────────────────────────────────────────────────


@router.post("/w/{workspace_id}/ops", response_model=PostOpsResponse)
async def post_ops(
    workspace_id: uuid.UUID,
    body: PostOpsRequest,
    db: AsyncSession = Depends(get_db),
    current_member: Member = Depends(get_current_member),
) -> PostOpsResponse:
    _authorize_workspace(workspace_id, current_member.user_id)
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

    # Control verification runs before the chain-gap check below, so a
    # mispositioned register yields `member_register_not_first` and never the
    # 409 — #551's chain verdict only ever sees registers already at seq 1.
    chained_members = await _verify_control_ops(db, workspace_id, current_member, parsed)

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
                detail={"code": "author_chain_conflict"},
            ) from exc

    for member in chained_members:
        member.chained_at = member.chained_at or datetime.now(UTC)
    await db.commit()
    return PostOpsResponse(results=results)


async def _verify_control_ops(
    db: AsyncSession,
    workspace_id: uuid.UUID,
    current_member: Member,
    parsed: list[tuple[bytes, OpHeader]],
) -> list[Member]:
    """Check every ``op_class=2`` op in the batch, in D2's order.

    Returns the Members whose registration this batch materialises.  Every
    rejection is a 422 with a structured detail carrying the batch ``index``:
    one fail-closed family, so #549 can open control types up by adding cases
    rather than by loosening the failure mode.
    """
    to_chain: list[Member] = []
    root_pk: bytes | None = None
    for index, (envelope, header) in enumerate(parsed):
        if header.op_class != OP_CLASS_CONTROL:
            continue

        _header_bytes, body, _signature = split_envelope(envelope)
        try:
            payload_bytes = parse_body(body)
        except EnvelopeError as exc:
            # A body the framing cannot even delimit never reaches control
            # parsing — same fail-closed family, its own code.
            raise _unprocessable(exc.reason, index=index) from exc

        try:
            payload = ControlPayload.decode(payload_bytes)
            payload.require_served_type()
        except UnsupportedControlTypeError as exc:
            raise _unprocessable(exc.reason, index=index, type=exc.observed_type) from exc
        except ControlPayloadError as exc:
            raise _unprocessable(exc.reason, index=index) from exc

        if header.author_seq != 1:
            # A member_register is its author's *first* op.  The chain rule only
            # guarantees that an author's first op is seq 1; it does not
            # guarantee that seq 1 is the register.
            raise _unprocessable(
                "member_register_not_first", index=index, author_seq=header.author_seq
            )

        if root_pk is None:
            escrow = await db.get(RecoveryEscrow, (workspace_id, current_member.user_id))
            # No escrow means no Root the server can check against, so nothing
            # can be Root-signed: fail closed rather than materialise on trust.
            root_pk = escrow.root_pk if escrow is not None else b""
        try:
            verify_registration_certificate(payload.cert_bytes, payload.root_sig, root_pk)
            certificate = payload.certificate()
        except ControlPayloadError as exc:
            raise _unprocessable(exc.reason, index=index) from exc

        if certificate.member_id != header.author_member_id:
            raise _unprocessable("cert_member_mismatch", index=index)
        if certificate.sign_pk != current_member.sign_pk:
            raise _unprocessable("cert_key_mismatch", index=index)
        to_chain.append(current_member)
    return to_chain


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
                detail={
                    "code": "author_chain_gap",
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
    """``since`` is a pure client parameter — no cursor is persisted (review F17)."""
    _authorize_workspace(workspace_id, current_member.user_id)
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
