"""Standalone CRUD for actions (ADR-0001 story 1 — issue #471).

These endpoints are called by the PowerSync BackendConnector to upload offline
mutations for the ``by_user_actions`` sync shape.  Story 1 is pure plumbing —
no DAO writes Action rows yet — but the routes exist so the upload path is
complete the moment story 2 starts writing them, and so the backfilled rows a
local device mints during migration have somewhere to converge (upsert-on-
replay, ADR-0015).  They follow the same contract as capture_routes.py:

- POST dedupes on the client-generated ``id``: a same-user id match upserts
  the submitted client-owned fields onto the stored row and returns it (2xx),
  so a consolidated replay carrying newer offline edits converges the server
  row (upsert-on-replay, ADR-0015).  A cross-user id collision is a 409.
- ``user_id`` is server-owned — always derived from the JWT; the denormalized
  value in the connector payload is ignored by the schemas.
- Parent/ownership checks happen at route level (404): the SQLite test harness
  does not enforce FKs, and on Postgres an FK violation would be a 500
  (transient → infinite retry) instead of a fatal 4xx.
- DELETE returns 404 when the row is already gone; the connector's fatal-4xx
  path skips it harmlessly (idempotent delete, docs/SYNC.md).

There is deliberately **no** partial unique index on ``(outcome_id) WHERE
role = 'current'`` (Alembic 0028 docstring, ADR-0019/§9 of the plan): a unique
violation would surface as a 500 → infinite retry, and catching it to 4xx would
dead-letter a legitimate replay.  The 0..1-current invariant is application-
enforced in later stories, not by the route or a constraint.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.database import get_db
from app.todos.models import Action, Todo
from app.todos.schemas import ActionCreate, ActionOut, ActionUpdate

router = APIRouter()


async def _require_owned_action(db: AsyncSession, action_id: str, current_user: User) -> Action:
    action = await db.get(Action, action_id)
    if not action or action.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Action not found")
    return action


async def _require_owned_todo(db: AsyncSession, todo_id: str, current_user: User) -> None:
    todo = await db.get(Todo, todo_id)
    if not todo or todo.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Todo not found")


@router.post("/actions/", response_model=ActionOut, status_code=status.HTTP_201_CREATED)
async def create_action(
    body: ActionCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Action:
    # Ownership at route level (404), never left to the FK — see module docstring.
    await _require_owned_todo(db, body.outcome_id, current_user)

    data = body.model_dump(exclude_unset=True)
    data.pop("id", None)
    # Upsert-on-replay (ADR-0015): a same-user id match applies the submitted
    # client-owned fields to the stored row and returns it, so a consolidated
    # replay that carries newer offline edits converges the server row instead
    # of reverting them one checkpoint later.  A cross-user id collision is a
    # real anomaly and stays a 409.
    if body.id is not None:
        existing = await db.get(Action, body.id)
        if existing:
            if existing.user_id != current_user.id:
                raise HTTPException(status_code=409, detail="Action id already exists")
            for field, value in data.items():
                setattr(existing, field, value)
            await db.commit()
            await db.refresh(existing)
            return existing
    action = Action(
        **({"id": body.id} if body.id is not None else {}),
        user_id=current_user.id,
        **data,
    )
    db.add(action)
    await db.commit()
    await db.refresh(action)
    return action


@router.patch("/actions/{action_id}", response_model=ActionOut)
async def update_action(
    action_id: str,
    body: ActionUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> Action:
    action = await _require_owned_action(db, action_id, current_user)
    data = body.model_dump(exclude_unset=True)
    # A re-parent PATCH must re-check ownership of the new Outcome (404), same
    # rationale as create.
    if "outcome_id" in data:
        await _require_owned_todo(db, data["outcome_id"], current_user)
    for field, value in data.items():
        setattr(action, field, value)
    await db.commit()
    await db.refresh(action)
    return action


@router.delete("/actions/{action_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_action(
    action_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    action = await _require_owned_action(db, action_id, current_user)
    await db.delete(action)
    await db.commit()
