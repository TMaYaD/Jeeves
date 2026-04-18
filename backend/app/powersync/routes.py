from datetime import timedelta

from fastapi import APIRouter, Depends, Response

from app.auth.dependencies import get_current_user
from app.auth.models import User
from app.auth.tokens import create_access_token
from app.config import settings

router = APIRouter()

# PowerSync tokens are short-lived; the SDK re-fetches automatically on 401.
_POWERSYNC_TOKEN_EXPIRE_MINUTES = 5


@router.get("/credentials")
async def get_powersync_credentials(
    response: Response,
    current_user: User = Depends(get_current_user),
) -> dict[str, str]:
    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
    token = create_access_token(
        data={"sub": current_user.id, "aud": "jeeves"},
        expires_delta=timedelta(minutes=_POWERSYNC_TOKEN_EXPIRE_MINUTES),
    )
    return {
        "token": token,
        "powersync_url": settings.powersync_url,
    }
