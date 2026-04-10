from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# Ensure all models are registered with SQLAlchemy metadata.
import app.auth.models  # noqa: F401
import app.todos.models  # noqa: F401
from app.ai import routes as ai_routes
from app.auth import routes as auth_routes
from app.config import settings
from app.database import engine
from app.health import routes as health_routes
from app.todos import routes as todo_routes


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    # Startup
    yield
    # Shutdown
    await engine.dispose()


app = FastAPI(
    title="Jeeves API",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_routes.router)
app.include_router(auth_routes.router)
app.include_router(todo_routes.router)
app.include_router(ai_routes.router)
