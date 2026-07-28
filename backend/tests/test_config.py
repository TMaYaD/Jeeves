import pytest
from pydantic import ValidationError

from app.config import Settings


@pytest.mark.parametrize(
    "input_url",
    [
        "postgres://u:p@h:5432/db",
        "postgresql://u:p@h:5432/db",
        "postgresql+asyncpg://u:p@h:5432/db",
    ],
)
def test_database_url_normalized_to_asyncpg(
    monkeypatch: pytest.MonkeyPatch, input_url: str
) -> None:
    monkeypatch.setenv("DATABASE_URL", input_url)
    monkeypatch.setenv("SECRET_KEY", "test-secret")
    settings = Settings()
    assert settings.database_url == "postgresql+asyncpg://u:p@h:5432/db"


def test_database_url_passes_through_non_postgres_schemes(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "sqlite+aiosqlite:///:memory:")
    monkeypatch.setenv("SECRET_KEY", "test-secret")
    settings = Settings()
    assert settings.database_url == "sqlite+aiosqlite:///:memory:"


@pytest.mark.parametrize("rounds", ["3", "32", "0"])
def test_rejects_bcrypt_rounds_outside_valid_range(
    monkeypatch: pytest.MonkeyPatch, rounds: str
) -> None:
    monkeypatch.setenv("SECRET_KEY", "test-secret")
    monkeypatch.setenv("BCRYPT_ROUNDS", rounds)
    with pytest.raises(ValidationError, match="between 4 and 31"):
        Settings()


def test_rejects_weak_bcrypt_rounds_in_production(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SECRET_KEY", "a-real-production-secret")
    monkeypatch.setenv("APP_ENV", "production")
    monkeypatch.setenv("BCRYPT_ROUNDS", "8")
    with pytest.raises(ValidationError, match="12 in production"):
        Settings()


def test_accepts_low_but_valid_rounds_outside_production(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SECRET_KEY", "test-secret")
    monkeypatch.setenv("APP_ENV", "test")
    monkeypatch.setenv("BCRYPT_ROUNDS", "4")
    settings = Settings()
    assert settings.bcrypt_rounds == 4


@pytest.mark.parametrize(
    "version",
    [
        "0.0.0-dev",  # the un-deployed default
        "1.2.3-test",  # what the test suite and Backend CI inject
        "0.1.0",  # the three-segment form compute-server-version.sh emits
        "0.1.0.1",  # the four-segment form it emits once an inner patch exists
    ],
)
def test_accepts_the_version_forms_the_pipeline_produces(
    monkeypatch: pytest.MonkeyPatch, version: str
) -> None:
    monkeypatch.setenv("SECRET_KEY", "test-secret")
    monkeypatch.setenv("SERVER_VERSION", version)
    settings = Settings()
    assert settings.server_version == version


@pytest.mark.parametrize("version", ["", "latest", "0.1", "server/v0.1.0", "v0.1.0", "0.1.0 "])
def test_rejects_a_server_version_that_is_not_version_shaped(
    monkeypatch: pytest.MonkeyPatch, version: str
) -> None:
    # settings.server_version is published verbatim by /health and by the
    # OpenAPI document, so a bad deploy-time value must fail settings
    # construction rather than becoming the version the server claims.
    monkeypatch.setenv("SECRET_KEY", "test-secret")
    monkeypatch.setenv("SERVER_VERSION", version)
    with pytest.raises(ValidationError, match="SERVER_VERSION"):
        Settings()
