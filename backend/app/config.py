import logging
from typing import Literal

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_logger = logging.getLogger(__name__)


class Settings(BaseSettings):
    # Env vars are read unprefixed (DATABASE_URL, REDIS_URL, SECRET_KEY, ...)
    # to align with platform conventions (dokku service-link, Anthropic SDK, etc.).
    model_config = SettingsConfigDict(env_file=".env")

    # Environment. Use APP_ENV rather than the too-generic ENV.
    env: Literal["development", "test", "production"] = Field(
        default="development",
        validation_alias="APP_ENV",
    )

    # Server version.  Backend CD sets SERVER_VERSION on the Dokku app before
    # every push, from the tag it just cut (infra/ci/compute-server-version.sh);
    # Dokku builds from a git archive with no `.git`, so deploy-time env is the
    # only place the running process can learn it.  The default names a local or
    # otherwise un-deployed build honestly rather than claiming a release.
    server_version: str = "0.0.0-dev"

    # Database.  Dokku-postgres (and Heroku) inject `postgres://...`, but
    # SQLAlchemy 2.x only accepts `postgresql://`; we also need the `+asyncpg`
    # driver suffix.  Both are handled by `_normalize_database_url` below.
    database_url: str = "postgresql+asyncpg://jeeves:jeeves@localhost:5432/jeeves"

    # PowerSync
    powersync_url: str = "http://localhost:8080"

    # Auth
    secret_key: str = "insecure-dev-key"

    # bcrypt work factor for password hashing.  Default 12 is the production
    # value; the test suite lowers it (via BCRYPT_ROUNDS) so its ~150 register()
    # calls don't dominate the run — the real hashing code path is still used.
    bcrypt_rounds: int = 12

    @model_validator(mode="after")
    def _normalize_database_url(self) -> "Settings":
        scheme, _, rest = self.database_url.partition("://")
        if scheme == "postgres" or scheme == "postgresql":
            self.database_url = f"postgresql+asyncpg://{rest}"
        return self

    @model_validator(mode="after")
    def _validate_secret_key(self) -> "Settings":
        if self.secret_key == "insecure-dev-key":
            if self.env not in ("development", "test"):
                raise ValueError(f"SECRET_KEY must be explicitly set when APP_ENV={self.env!r}")
            _logger.warning(
                "Using insecure default secret_key — this is only acceptable in development/test"
            )
        return self

    @model_validator(mode="after")
    def _validate_bcrypt_rounds(self) -> "Settings":
        # bcrypt.gensalt() only accepts 4–31 and raises ValueError otherwise;
        # validate here so a misconfiguration fails at startup rather than on
        # the first password hash. Production must not run below the default 12.
        if not 4 <= self.bcrypt_rounds <= 31:
            raise ValueError(
                f"BCRYPT_ROUNDS must be between 4 and 31 (bcrypt's valid range); "
                f"got {self.bcrypt_rounds}"
            )
        if self.env == "production" and self.bcrypt_rounds < 12:
            raise ValueError(f"BCRYPT_ROUNDS must be >= 12 in production; got {self.bcrypt_rounds}")
        return self

    algorithm: str = "HS256"
    access_token_expire_minutes: int = 15  # short-lived; renewed via refresh token
    refresh_token_expire_days: int = 365  # 1 year

    # PowerSync's JWKS validator selects a key by `kid`.  Must match the
    # `kid` declared in infra/powersync/sync-config.yaml's client_auth.jwks.
    jwt_kid: str = "jeeves-dev"

    # Member proof-of-possession challenges (`POST /members/{m}/challenge`).
    # The route is unauthenticated on purpose — possession of the Device's
    # signing key is the credential being proved — so the only thing standing
    # between it and an unbounded nonce mill is this per-member ceiling.  A
    # Device asks for a challenge once per transport credential and renews by
    # refresh thereafter, so a day's honest traffic is single digits; the
    # default leaves room for retries and still turns a flood into a 429.
    # Settings fields rather than module constants so a test can lower the cap
    # instead of issuing the production number of requests to reach it.
    member_challenge_daily_limit: int = 120
    member_challenge_window_seconds: int = 86_400

    # Realtime signal socket (`WS /w/{w}/signal`).  The keepalive interval sits
    # below Dokku's default 60 s `proxy_read_timeout` so the proxy never reaps an
    # idle-but-live subscription; the client's idle deadline is three intervals.
    # The auth-frame deadline bounds how long an unauthenticated socket may sit
    # open.  Both are Settings fields so the socket tests can run in
    # milliseconds instead of waiting out the production values.
    signal_keepalive_interval_seconds: float = 25.0
    signal_auth_frame_deadline_seconds: float = 10.0

    # CORS — set to actual Flutter app origin(s) in production
    allowed_origins: list[str] = ["*"]

    # AI
    anthropic_api_key: str = ""

    # Redis (Celery broker)
    redis_url: str = "redis://localhost:6379/0"

    # Push notifications
    firebase_credentials_path: str = ""


settings = Settings()
