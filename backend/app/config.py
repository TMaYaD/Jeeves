from typing import Literal

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="JEEVES_", env_file=".env")

    # Environment
    env: Literal["development", "test", "production"] = "development"

    # Database
    database_url: str = "postgresql+asyncpg://jeeves:jeeves@localhost:5432/jeeves"

    # Electric SQL
    electric_url: str = "http://localhost:3000"

    # Auth
    secret_key: str = "insecure-dev-key"

    @model_validator(mode="after")
    def _require_secret_key_in_production(self) -> "Settings":
        if self.env == "production" and self.secret_key == "insecure-dev-key":
            raise ValueError("JEEVES_SECRET_KEY must be set in production")
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
