import asyncio
import os
from logging.config import fileConfig

from sqlalchemy import pool, text
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

import app.auth.models  # noqa: F401  -- register all models
import app.todos.models  # noqa: F401
from alembic import context
from app.database import Base

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Allow env var to override alembic.ini database URL
if db_url := os.environ.get("JEEVES_DATABASE_URL"):
    config.set_main_option("sqlalchemy.url", db_url)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )
    with context.begin_transaction():
        context.run_migrations()


# Advisory lock ID to prevent concurrent migration runs (e.g. scaled replicas).
_MIGRATION_LOCK_ID = 7_239_183_491  # arbitrary unique int


def do_run_migrations(connection: Connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata)
    with context.begin_transaction():
        # pg_advisory_xact_lock is transaction-scoped: auto-releases on commit/rollback,
        # and must be acquired inside the transaction to avoid triggering SA autobegin
        # before context.begin_transaction() can take ownership of the connection.
        connection.execute(text(f"SELECT pg_advisory_xact_lock({_MIGRATION_LOCK_ID})"))
        context.run_migrations()


async def run_async_migrations() -> None:
    connectable = async_engine_from_config(
        config.get_section(config.config_ini_section, {}),
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
        await connection.commit()
    await connectable.dispose()


def run_migrations_online() -> None:
    asyncio.run(run_async_migrations())


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
