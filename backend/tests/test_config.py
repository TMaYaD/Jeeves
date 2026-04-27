import pytest

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
