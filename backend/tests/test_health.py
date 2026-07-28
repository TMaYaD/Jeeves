import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app


@pytest.mark.asyncio
async def test_health_reports_status_and_deployed_version() -> None:
    # 1.2.3-test is seeded into the environment by conftest.py *before* app.main
    # is imported, so this asserts the real Settings object read the real env
    # var and the endpoint reported it — the same path a Dokku deploy uses when
    # it sets SERVER_VERSION from the tag it just cut.
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "version": "1.2.3-test"}


def test_openapi_version_tracks_the_deployed_version() -> None:
    # main.py used to hardcode a version that nothing kept in step with reality;
    # the OpenAPI document now reports the same value /health does.
    assert app.version == "1.2.3-test"
