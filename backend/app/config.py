from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="JEEVES_", env_file=".env")

    # Database
    database_url: str = "postgresql+asyncpg://jeeves:jeeves@localhost:5432/jeeves"

    # Electric SQL
    electric_url: str = "http://localhost:3000"

    # Auth
    secret_key: str = "changeme-in-production"
    algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24 * 7  # 1 week

    # AI
    anthropic_api_key: str = ""

    # Redis (Celery broker)
    redis_url: str = "redis://localhost:6379/0"

    # Push notifications
    firebase_credentials_path: str = ""


settings = Settings()
