"""Startup migration runner: ``python -m app.migrate``.

Wraps ``alembic upgrade head`` with drift detection so that a mismatch between
the live schema and the ``alembic_version`` stamp surfaces an actionable
diagnostic instead of an opaque crash-loop (issue #382).

The runner never auto-stamps the version table: a schema that merely *looks*
migrated may genuinely be behind, and stamping it would silently skip
migrations. See docs/adr/0012-no-auto-stamp-on-migration-drift.md.
"""

import asyncio
import sys
from pathlib import Path
from typing import NoReturn

import sqlalchemy as sa
from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from alembic.script import ScriptDirectory
from alembic.util import CommandError
from sqlalchemy.engine import Connection
from sqlalchemy.exc import ProgrammingError

from alembic import command
from app.database import engine

_BACKEND_DIR = Path(__file__).resolve().parents[1]

# PostgreSQL SQLSTATE codes raised when a migration re-creates an object that
# already exists — the signature of schema-ahead-of-stamp drift.
# not configurable: protocol constants defined by PostgreSQL.
_DUPLICATE_OBJECT_PGCODES = frozenset(
    {
        "42701",  # duplicate_column
        "42P07",  # duplicate_table
        "42710",  # duplicate_object
    }
)

# Created by the very first migration; its presence means the schema is (at
# least partially) initialized even when alembic_version holds no stamp.
_SENTINEL_TABLE = "todos"

_RECOVERY_STEPS = (
    'Recovery (see infra/README.md, "Recovering from schema/version drift"):\n'
    "  1. Back up the database, verify that the schema AND data effects of\n"
    "     every migration up to your chosen revision are already present,\n"
    "     then record that revision without re-running migrations:\n"
    "       cd backend && alembic stamp <revision>\n"
    "  2. Dev only — reset the database volume (DESTROYS ALL DATA):\n"
    "       cd infra && podman compose down -v"
)


def _alembic_config() -> Config:
    # Resolve paths relative to this file so the runner works from any CWD
    # (compose container, dokku release container, test runner).
    config = Config(str(_BACKEND_DIR / "alembic.ini"))
    config.set_main_option("script_location", str(_BACKEND_DIR / "alembic"))
    return config


def _run_upgrade(config: Config) -> None:
    command.upgrade(config, "head")


def _read_db_state(conn: Connection) -> tuple[str | None, bool]:
    current = MigrationContext.configure(conn).get_current_revision()
    tables = sa.inspect(conn).get_table_names()
    return current, _SENTINEL_TABLE in tables


async def _db_state() -> tuple[str | None, bool]:
    """Return (current alembic revision, whether the sentinel table exists).

    Uses the application's shared engine so the pre-flight connects exactly
    as the app does (same driver and TLS behaviour).
    """
    try:
        async with engine.connect() as conn:
            return await conn.run_sync(_read_db_state)
    finally:
        await engine.dispose()


def _pgcode(exc: BaseException) -> str | None:
    """Walk a (possibly wrapped) database error for its PostgreSQL SQLSTATE."""
    seen: set[int] = set()
    node: BaseException | None = exc
    while node is not None and id(node) not in seen:
        seen.add(id(node))
        for attr in ("pgcode", "sqlstate"):
            code = getattr(node, attr, None)
            if isinstance(code, str) and code:
                return code
        node = getattr(node, "orig", None) or node.__cause__
    return None


def _fail(message: str) -> NoReturn:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def main() -> int:
    config = _alembic_config()
    script = ScriptDirectory.from_config(config)
    head = script.get_current_head()
    if head is None:
        print("No migration scripts found; nothing to do.")
        return 0

    current, schema_present = asyncio.run(_db_state())

    if current is None and schema_present:
        _fail(
            "Schema/version drift detected: the database already contains the\n"
            f'"{_SENTINEL_TABLE}" table, but alembic_version holds no revision stamp.\n'
            "Running every migration from scratch would fail on the existing\n"
            "objects, so no migration was attempted.\n\n"
            f"{_RECOVERY_STEPS}"
        )

    if current is not None:
        try:
            script.get_revision(current)
        except CommandError:
            _fail(
                "Schema/version drift detected: the database is stamped with alembic\n"
                f"revision {current!r}, which does not exist in this checkout (head\n"
                f"here is {head!r}). It was probably migrated by a newer or divergent\n"
                "branch; running this checkout's migrations against it is unsafe.\n\n"
                f"{_RECOVERY_STEPS}"
            )

    if current == head:
        print(f"Database already at head revision {head}; no migrations to run.")
        return 0

    pending = [rev.revision for rev in script.iterate_revisions(head, current)]
    pending.reverse()  # oldest first
    print(
        f"Upgrading from revision {current or '<empty database>'} to {head} "
        f"(pending: {', '.join(pending)})."
    )
    try:
        _run_upgrade(config)
    except ProgrammingError as exc:
        code = _pgcode(exc)
        if code in _DUPLICATE_OBJECT_PGCODES:
            _fail(
                "Schema/version drift detected: a pending migration tried to create\n"
                f"a database object that already exists (SQLSTATE {code}).\n"
                f"  current DB revision: {current or '<none>'}\n"
                f"  head revision:       {head}\n"
                f"  pending revisions:   {', '.join(pending)}\n"
                f"  error:               {exc.orig}\n"
                "The live schema is ahead of the alembic_version stamp for at least\n"
                "one pending revision. No migration state was changed (the upgrade\n"
                "transaction rolled back).\n\n"
                f"{_RECOVERY_STEPS}"
            )
        raise
    print(f"Migrations applied; database is now at revision {head}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
