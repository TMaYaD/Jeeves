"""Standalone CRUD for focus_sessions, focus_session_tasks, and time_logs.

These endpoints are called by the PowerSync BackendConnector to upload
offline mutations for the focus-session sync shapes (#383).  They follow the
same contract as tag_routes.py:

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
from app.todos.models import FocusSession, FocusSessionTask, TimeLog, Todo
from app.todos.schemas import (
    FocusSessionCreate,
    FocusSessionOut,
    FocusSessionTaskCreate,
    FocusSessionTaskOut,
    FocusSessionTaskUpdate,
    FocusSessionUpdate,
    TimeLogCreate,
    TimeLogOut,
    TimeLogUpdate,
)

router = APIRouter()


async def _require_owned_todo(db: AsyncSession, todo_id: str, current_user: User) -> None:
    todo = await db.get(Todo, todo_id)
    if not todo or todo.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Todo not found")


async def _require_owned_session(
    db: AsyncSession, session_id: str, current_user: User
) -> FocusSession:
    session = await db.get(FocusSession, session_id)
    if not session or session.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="FocusSession not found")
    return session


# ── FocusSessions ─────────────────────────────────────────────────────────────


@router.post(
    "/focus_sessions/", response_model=FocusSessionOut, status_code=status.HTTP_201_CREATED
)
async def create_focus_session(
    body: FocusSessionCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> FocusSession:
    # Idempotency: return the existing session if the client id already exists.
    if body.id is not None:
        existing = await db.get(FocusSession, body.id)
        if existing:
            if existing.user_id == current_user.id:
                return existing
            raise HTTPException(status_code=409, detail="FocusSession id already exists")
    if body.current_task_id is not None:
        await _require_owned_todo(db, body.current_task_id, current_user)
    session = FocusSession(
        **({"id": body.id} if body.id is not None else {}),
        user_id=current_user.id,
        started_at=body.started_at,
        ended_at=body.ended_at,
        current_task_id=body.current_task_id,
    )
    db.add(session)
    await db.commit()
    await db.refresh(session)
    return session


@router.patch("/focus_sessions/{session_id}", response_model=FocusSessionOut)
async def update_focus_session(
    session_id: str,
    body: FocusSessionUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> FocusSession:
    session = await _require_owned_session(db, session_id, current_user)
    data = body.model_dump(exclude_unset=True)
    if data.get("current_task_id") is not None:
        await _require_owned_todo(db, data["current_task_id"], current_user)
    for field, value in data.items():
        setattr(session, field, value)
    await db.commit()
    await db.refresh(session)
    return session


@router.delete("/focus_sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_focus_session(
    session_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    session = await _require_owned_session(db, session_id, current_user)
    # Neither focus_session_tasks.focus_session_id nor time_logs.focus_session_id
    # has ON DELETE CASCADE, so clear them here — a Postgres FK violation would
    # 500 and wedge the CRUD queue permanently.  Child task rows go with the
    # session; time logs are the user's time data, so they are detached
    # (SET NULL semantics), never deleted.
    await db.execute(
        sa.delete(FocusSessionTask).where(FocusSessionTask.focus_session_id == session_id)
    )
    await db.execute(
        sa.update(TimeLog)
        .where(TimeLog.focus_session_id == session_id)
        .values(focus_session_id=None)
    )
    await db.delete(session)
    await db.commit()


# ── FocusSessionTasks ─────────────────────────────────────────────────────────


@router.post(
    "/focus_session_tasks/",
    response_model=FocusSessionTaskOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_focus_session_task(
    body: FocusSessionTaskCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> FocusSessionTask:
    await _require_owned_session(db, body.focus_session_id, current_user)
    await _require_owned_todo(db, body.task_id, current_user)

    # Idempotency: return if already exists by id, but only when the stored
    # relation matches exactly; a mismatched relation is a conflict.
    if body.id is not None:
        result = await db.execute(select(FocusSessionTask).where(FocusSessionTask.id == body.id))
        existing_by_id = result.scalar_one_or_none()
        if existing_by_id is not None:
            if (
                existing_by_id.focus_session_id == body.focus_session_id
                and existing_by_id.task_id == body.task_id
            ):
                return existing_by_id
            raise HTTPException(
                status_code=409,
                detail="FocusSessionTask id already used for a different relation",
            )

    # Idempotency: return if the (focus_session_id, task_id) pair already exists.
    result = await db.execute(
        select(FocusSessionTask).where(
            FocusSessionTask.focus_session_id == body.focus_session_id,
            FocusSessionTask.task_id == body.task_id,
        )
    )
    existing_pair = result.scalar_one_or_none()
    if existing_pair is not None:
        return existing_pair

    row = FocusSessionTask(
        **({"id": body.id} if body.id is not None else {}),
        focus_session_id=body.focus_session_id,
        task_id=body.task_id,
        position=body.position,
        disposition=body.disposition,
        user_id=current_user.id,
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    return row


@router.patch("/focus_session_tasks/{fst_id}", response_model=FocusSessionTaskOut)
async def update_focus_session_task(
    fst_id: str,
    body: FocusSessionTaskUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> FocusSessionTask:
    # Lookup by the client-assigned id column — the row PowerSync PATCHes by;
    # the composite (focus_session_id, task_id) PK is the domain key.
    result = await db.execute(select(FocusSessionTask).where(FocusSessionTask.id == fst_id))
    row = result.scalar_one_or_none()
    if row is None or row.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="FocusSessionTask not found")
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(row, field, value)
    await db.commit()
    await db.refresh(row)
    return row


@router.delete("/focus_session_tasks/{fst_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_focus_session_task(
    fst_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    result = await db.execute(select(FocusSessionTask).where(FocusSessionTask.id == fst_id))
    row = result.scalar_one_or_none()
    if row is None or row.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="FocusSessionTask not found")
    await db.delete(row)
    await db.commit()


# ── TimeLogs ──────────────────────────────────────────────────────────────────


@router.post("/time_logs/", response_model=TimeLogOut, status_code=status.HTTP_201_CREATED)
async def create_time_log(
    body: TimeLogCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> TimeLog:
    await _require_owned_todo(db, body.task_id, current_user)
    if body.focus_session_id is not None:
        await _require_owned_session(db, body.focus_session_id, current_user)

    # Idempotency: return the existing log if the client id already exists.
    if body.id is not None:
        existing = await db.get(TimeLog, body.id)
        if existing:
            if existing.user_id == current_user.id:
                return existing
            raise HTTPException(status_code=409, detail="TimeLog id already exists")

    log = TimeLog(
        **({"id": body.id} if body.id is not None else {}),
        user_id=current_user.id,
        task_id=body.task_id,
        started_at=body.started_at,
        ended_at=body.ended_at,
        focus_session_id=body.focus_session_id,
    )
    db.add(log)
    await db.commit()
    await db.refresh(log)
    return log


@router.patch("/time_logs/{log_id}", response_model=TimeLogOut)
async def update_time_log(
    log_id: str,
    body: TimeLogUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> TimeLog:
    log = await db.get(TimeLog, log_id)
    if not log or log.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="TimeLog not found")
    data = body.model_dump(exclude_unset=True)
    if data.get("task_id") is not None:
        await _require_owned_todo(db, data["task_id"], current_user)
    if data.get("focus_session_id") is not None:
        await _require_owned_session(db, data["focus_session_id"], current_user)
    for field, value in data.items():
        setattr(log, field, value)
    await db.commit()
    await db.refresh(log)
    return log


@router.delete("/time_logs/{log_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_time_log(
    log_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    log = await db.get(TimeLog, log_id)
    if not log or log.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="TimeLog not found")
    await db.delete(log)
    await db.commit()
