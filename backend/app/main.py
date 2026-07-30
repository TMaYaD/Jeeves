from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# Ensure all models are registered with SQLAlchemy metadata.
import app.auth.models as _auth_models  # noqa: F401
import app.sync.models as _sync_models  # noqa: F401
from app.auth.routes import router as auth_router
from app.config import settings
from app.database import engine
from app.health.routes import router as health_router
from app.sync.routes import router as sync_router


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
app.include_router(sync_router, tags=["sync"])
