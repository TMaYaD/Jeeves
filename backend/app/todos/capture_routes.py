"""Standalone CRUD for captures, capture_outcomes, and capture_tags.

These endpoints are called by the PowerSync BackendConnector to upload
offline mutations for the capture sync shapes (ADR-0006 — the split of the
Inbox out of the conflated todos table).  They follow the same contract as
focus_session_routes.py:

- POST dedupes on the client-generated ``id`` so an offline replay is
  idempotent: a matching row returns 2xx; the same id claimed for a
  different row is a 409.
- ``user_id`` is server-owned — always derived from the JWT; the
  denormalized value in the connector payload is ignored by the schemas.
- Parent/ownership checks happen at route level (404): the SQLite test
  harness does not enforce FKs, and on Postgres an FK violation would be a
  500 (transient → infinite retry) instead of a fatal 4xx.
- DELETE returns 404 when the row is already gone; the connector's
  fatal-4xx path skips it harmlessly (idempotent delete, docs/SYNC.md).
"""

import sqlalchemy as sa
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.database import get_db
from app.todos.models import Capture, CaptureOutcome, CaptureTag, Tag, Todo
from app.todos.schemas import (
    CaptureCreate,
    CaptureOut,
    CaptureOutcomeCreate,
    CaptureOutcomeOut,
    CaptureOutcomeUpdate,
    CaptureTagCreate,
    CaptureTagOut,
    CaptureUpdate,
)

router = APIRouter()


async def _require_owned_capture(db: AsyncSession, capture_id: str, current_user: User) -> Capture:
    capture = await db.get(Capture, capture_id)
    if not capture or capture.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Capture not found")
    return capture


async def _require_owned_todo(db: AsyncSession, todo_id: str, current_user: User) -> None:
    todo = await db.get(Todo, todo_id)
    if not todo or todo.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Todo not found")


async def _require_owned_tag(db: AsyncSession, tag_id: str, current_user: User) -> None:
    tag = await db.get(Tag, tag_id)
    if not tag or tag.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Tag not found")


# ── Captures ──────────────────────────────────────────────────────────────────


@router.post("/captures/", response_model=CaptureOut, status_code=status.HTTP_201_CREATED)
async def create_capture(
    body: CaptureCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Capture:
    # Idempotency: return the existing capture if the client id already exists.
    if body.id is not None:
        existing = await db.get(Capture, body.id)
        if existing:
            if existing.user_id == current_user.id:
                return existing
            raise HTTPException(status_code=409, detail="Capture id already exists")
    data = body.model_dump(exclude_unset=True)
    data.pop("id", None)
    capture = Capture(
        **({"id": body.id} if body.id is not None else {}),
        user_id=current_user.id,
        **data,
    )
    db.add(capture)
    await db.commit()
    await db.refresh(capture)
    return capture


@router.patch("/captures/{capture_id}", response_model=CaptureOut)
async def update_capture(
    capture_id: str,
    body: CaptureUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Capture:
    capture = await _require_owned_capture(db, capture_id, current_user)
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(capture, field, value)
    await db.commit()
    await db.refresh(capture)
    return capture


@router.delete("/captures/{capture_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_capture(
    capture_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    capture = await _require_owned_capture(db, capture_id, current_user)
    # Clear children first: the SQLite test harness does not honour ON DELETE
    # CASCADE, so a leftover child row would trip a Postgres FK violation only
    # in production (500 → infinite retry).  Delete them explicitly here.
    await db.execute(sa.delete(CaptureOutcome).where(CaptureOutcome.capture_id == capture_id))
    await db.execute(sa.delete(CaptureTag).where(CaptureTag.capture_id == capture_id))
    await db.delete(capture)
    await db.commit()


# ── CaptureOutcomes ───────────────────────────────────────────────────────────


@router.post(
    "/capture_outcomes/",
    response_model=CaptureOutcomeOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_capture_outcome(
    body: CaptureOutcomeCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> CaptureOutcome:
    await _require_owned_capture(db, body.capture_id, current_user)
    await _require_owned_todo(db, body.outcome_id, current_user)

    # Idempotency: return if already exists by id, but only when the stored
    # relation matches exactly; a mismatched relation is a conflict.
    if body.id is not None:
        result = await db.execute(select(CaptureOutcome).where(CaptureOutcome.id == body.id))
        existing_by_id = result.scalar_one_or_none()
        if existing_by_id is not None:
            if (
                existing_by_id.capture_id == body.capture_id
                and existing_by_id.outcome_id == body.outcome_id
            ):
                return existing_by_id
            raise HTTPException(
                status_code=409,
                detail="CaptureOutcome id already used for a different relation",
            )

    # Idempotency: return if the (capture_id, outcome_id) pair already exists.
    result = await db.execute(
        select(CaptureOutcome).where(
            CaptureOutcome.capture_id == body.capture_id,
            CaptureOutcome.outcome_id == body.outcome_id,
        )
    )
    existing_pair = result.scalar_one_or_none()
    if existing_pair is not None:
        return existing_pair

    data = body.model_dump(exclude_unset=True)
    data.pop("id", None)
    data.pop("capture_id", None)
    data.pop("outcome_id", None)
    row = CaptureOutcome(
        **({"id": body.id} if body.id is not None else {}),
        capture_id=body.capture_id,
        outcome_id=body.outcome_id,
        user_id=current_user.id,
        **data,
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return row


@router.patch("/capture_outcomes/{co_id}", response_model=CaptureOutcomeOut)
async def update_capture_outcome(
    co_id: str,
    body: CaptureOutcomeUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> CaptureOutcome:
    # Lookup by the client-assigned id column — the row PowerSync PATCHes by;
    # the composite (capture_id, outcome_id) PK is the domain key.
    result = await db.execute(select(CaptureOutcome).where(CaptureOutcome.id == co_id))
    row = result.scalar_one_or_none()
    if row is None or row.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="CaptureOutcome not found")
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(row, field, value)
    await db.commit()
    await db.refresh(row)
    return row


@router.delete("/capture_outcomes/{co_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_capture_outcome(
    co_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    result = await db.execute(select(CaptureOutcome).where(CaptureOutcome.id == co_id))
    row = result.scalar_one_or_none()
    if row is None or row.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="CaptureOutcome not found")
    await db.delete(row)
    await db.commit()


# ── CaptureTags ───────────────────────────────────────────────────────────────


@router.post("/capture_tags/", response_model=CaptureTagOut, status_code=status.HTTP_201_CREATED)
async def create_capture_tag(
    body: CaptureTagCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> CaptureTag:
    await _require_owned_capture(db, body.capture_id, current_user)
    await _require_owned_tag(db, body.tag_id, current_user)

    # Idempotency: return if already exists by id, but only when the stored
    # relation matches exactly; a mismatched relation is a conflict.
    if body.id is not None:
        result = await db.execute(select(CaptureTag).where(CaptureTag.id == body.id))
        existing_by_id = result.scalar_one_or_none()
        if existing_by_id is not None:
            if (
                existing_by_id.capture_id == body.capture_id
                and existing_by_id.tag_id == body.tag_id
            ):
                return existing_by_id
            raise HTTPException(
                status_code=409,
                detail="CaptureTag id already used for a different relation",
            )

    # Idempotency: return if the (capture_id, tag_id) pair already exists.
    result = await db.execute(
        select(CaptureTag).where(
            CaptureTag.capture_id == body.capture_id,
            CaptureTag.tag_id == body.tag_id,
        )
    )
    existing_pair = result.scalar_one_or_none()
    if existing_pair is not None:
        return existing_pair

    row = CaptureTag(
        **({"id": body.id} if body.id is not None else {}),
        capture_id=body.capture_id,
        tag_id=body.tag_id,
        user_id=current_user.id,
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return row


@router.delete("/capture_tags/{ct_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_capture_tag(
    ct_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    result = await db.execute(select(CaptureTag).where(CaptureTag.id == ct_id))
    row = result.scalar_one_or_none()
    if row is None or row.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="CaptureTag not found")
    await db.delete(row)
    await db.commit()
