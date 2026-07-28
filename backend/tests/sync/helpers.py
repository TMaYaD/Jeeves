"""Scaffolding shared across the sync suite.

Neither a fixture module nor a builder: these are the two chores every sync test
file was re-copying — unwrapping a route's structured error, and running a single
Alembic revision against a scratch engine.  Three verbatim copies of each is how
the assertion and the thing asserted drift apart, so they live here once.

Fixtures stay in ``conftest.py`` and artifact minting in ``builders.py``.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import sqlalchemy as sa
from alembic.operations import Operations
from alembic.runtime.migration import MigrationContext

VERSIONS_DIR = Path(__file__).resolve().parents[2] / "alembic" / "versions"


def detail_of(response: object) -> dict[str, object]:
    """The structured error object every route rejection carries.

    ``response`` is typed ``object`` because ``httpx.Response`` and the
    ``TestClient`` response are structurally interchangeable here and only
    ``.json()`` is used.
    """
    detail = response.json()["detail"]  # type: ignore[attr-defined]
    assert isinstance(detail, dict), detail
    return detail


def load_migration(name: str, filename: str) -> ModuleType:
    """Import one revision module by path, without going through Alembic's env."""
    spec = importlib.util.spec_from_file_location(name, VERSIONS_DIR / filename)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_migration(
    engine: sa.engine.Engine,
    module: ModuleType,
    *,
    downgrade: bool = False,
) -> None:
    """Apply one revision's ``upgrade()`` (or ``downgrade()``) to [engine]."""
    with engine.begin() as conn:
        ctx = MigrationContext.configure(conn)
        with Operations.context(ctx):
            (module.downgrade if downgrade else module.upgrade)()
