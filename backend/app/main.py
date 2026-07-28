from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# Ensure all models are registered with SQLAlchemy metadata.
import app.auth.models as _auth_models  # noqa: F401
import app.sync.models as _sync_models  # noqa: F401
import app.todos.models as _todo_models  # noqa: F401
from app.ai.routes import router as ai_router
from app.auth.routes import router as auth_router
from app.config import settings
from app.database import engine
from app.health.routes import router as health_router
from app.powersync.routes import router as powersync_router
from app.sync.routes import router as sync_router
from app.todos.action_routes import router as action_router
from app.todos.capture_routes import router as capture_router
from app.todos.focus_session_routes import router as focus_session_router
from app.todos.routes import router as todo_router
from app.todos.tag_routes import router as tag_router
from app.todos.user_preference_routes import router as user_preference_router


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    # Startup
    yield
    # Shutdown
    await engine.dispose()


app = FastAPI(
    title="Jeeves API",
    version=settings.server_version,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router)
app.include_router(auth_router)
app.include_router(todo_router)
app.include_router(tag_router, tags=["tags"])
app.include_router(focus_session_router, tags=["focus_sessions"])
app.include_router(capture_router, tags=["captures"])
app.include_router(action_router, tags=["actions"])
app.include_router(user_preference_router, tags=["user_preferences"])
app.include_router(ai_router)
app.include_router(powersync_router, prefix="/powersync", tags=["powersync"])
app.include_router(sync_router, tags=["sync"])
