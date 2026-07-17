"""Standalone CRUD for `user_preferences`.

Called by the PowerSync BackendConnector to upload offline writes to the
synced key-value preference store. Conflict resolution between local and
server rows is out of scope here (see issue #306); these endpoints just
apply the client's authoritative intent for rows it owns.
"""

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.database import get_db
from app.todos.models import UserPreference
from app.todos.schemas import (
    UserPreferenceCreate,
    UserPreferenceOut,
    UserPreferenceUpdate,
)

router = APIRouter()


@router.post(
    "/user_preferences/",
    response_model=UserPreferenceOut,
    status_code=status.HTTP_201_CREATED,
)
async def create_user_preference(
    body: UserPreferenceCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPreference:
    # Upsert-on-replay (ADR-0015): a same-user id match applies the submitted
    # client-owned fields to the stored row and returns it, so a consolidated
    # replay carrying newer offline edits converges the server row instead of
    # 409ing (PowerSync re-uploads the same CRUD entry on retry) or silently
    # discarding the newer values.  A cross-user id collision stays a 409.
    if body.id is not None:
        existing = await db.get(UserPreference, body.id)
        if existing is not None:
            if existing.user_id != current_user.id:
                raise HTTPException(status_code=409, detail="Preference id already exists")
            data = body.model_dump(exclude_unset=True)
            data.pop("id", None)
            for field, value in data.items():
                setattr(existing, field, value)
            await db.commit()
            await db.refresh(existing)
            return existing

    pref = UserPreference(
        **({"id": body.id} if body.id is not None else {}),
        user_id=current_user.id,
        key=body.key,
        value=body.value,
        updated_at=body.updated_at,
    )
    db.add(pref)
    await db.commit()
    await db.refresh(pref)
    return pref


@router.patch("/user_preferences/{pref_id}", response_model=UserPreferenceOut)
async def update_user_preference(
    pref_id: str,
    body: UserPreferenceUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserPreference:
    pref = await db.get(UserPreference, pref_id)
    if pref is None or pref.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Preference not found")
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(pref, field, value)
    await db.commit()
    await db.refresh(pref)
    return pref


@router.delete("/user_preferences/{pref_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_user_preference(
    pref_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> None:
    pref = await db.get(UserPreference, pref_id)
    if pref is None or pref.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Preference not found")
    await db.delete(pref)
    await db.commit()
