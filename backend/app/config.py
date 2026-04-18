import logging
from typing import Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_logger = logging.getLogger(__name__)


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="JEEVES_", env_file=".env")

    # Environment
    env: Literal["development", "test", "production"] = "development"

    # Database
    database_url: str = "postgresql+asyncpg://jeeves:jeeves@localhost:5432/jeeves"

    # PowerSync
    powersync_url: str = "http://localhost:8080"

    # Auth
    secret_key: str = "insecure-dev-key"

    @model_validator(mode="after")
    def _validate_secret_key(self) -> "Settings":
        if self.secret_key == "insecure-dev-key":
            if self.env not in ("development", "test"):
                raise ValueError(
                    f"JEEVES_SECRET_KEY must be explicitly set when JEEVES_ENV={self.env!r}"
                )
            _logger.warning(
                "Using insecure default secret_key — this is only acceptable in development/test"
            )
        return self

    algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24 * 7  # 1 week

    # CORS — set to actual Flutter app origin(s) in production
    allowed_origins: list[str] = ["*"]

    # AI
    anthropic_api_key: str = ""

    # Redis (Celery broker)
    redis_url: str = "redis://localhost:6379/0"

    # Push notifications
    firebase_credentials_path: str = ""


settings = Settings()
