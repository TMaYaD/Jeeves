from fastapi import APIRouter
from sqlalchemy import text

from app.config import settings
from app.database import AsyncSessionLocal

router = APIRouter()


@router.get("/health")
async def health() -> dict[str, str]:
    # The version is what lets a client say which server it talked to, so it
    # rides on the endpoint that is always reachable rather than behind auth.
    return {"status": "ok", "version": settings.server_version}


@router.get("/health/db")
async def health_db() -> dict[str, str]:
    async with AsyncSessionLocal() as session:
        await session.execute(text("SELECT 1"))
    return {"status": "ok"}
