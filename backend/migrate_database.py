"""Copy the live GSAT_Max SQLite database into isolated PostgreSQL storage.

Run this inside the existing service container before changing ``DATABASE_URL``::

    OLD_DATABASE_URL="$DATABASE_URL" \
    NEW_DATABASE_URL="postgresql://..." \
    DESTINATION_SCHEMA="gsatmax" \
    python backend/migrate_database.py

The destination role must already have ``gsatmax`` as its first search-path
schema. The script refuses to continue otherwise, applies Alembic migrations,
and copies all tables in foreign-key-safe order in one transaction. Re-running
is safe: a destination table that already contains rows is left unchanged.
"""

from __future__ import annotations

import os
from pathlib import Path
import sys

from alembic import command as alembic_command
from alembic.config import Config as AlembicConfig
from sqlalchemy import Engine, Integer, create_engine, func, select, text
from sqlalchemy.engine import Connection

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from backend.config import normalize_database_url  # noqa: E402
from backend.models import Base  # noqa: E402


def _connect_args(url: str) -> dict[str, object]:
    return {"check_same_thread": False} if url.startswith("sqlite") else {}


def _assert_destination_schema(engine: Engine, expected_schema: str) -> None:
    if engine.dialect.name != "postgresql":
        raise RuntimeError("NEW_DATABASE_URL must point to PostgreSQL.")
    with engine.connect() as connection:
        actual_schema = connection.scalar(text("SELECT current_schema()"))
    if actual_schema != expected_schema:
        raise RuntimeError(
            "Refusing to migrate into the wrong PostgreSQL schema: "
            f"expected {expected_schema!r}, got {actual_schema!r}."
        )


def _run_migrations(database_url: str) -> None:
    migration_config = AlembicConfig(str(PROJECT_ROOT / "alembic.ini"))
    migration_config.attributes["database_url"] = database_url
    alembic_command.upgrade(migration_config, "head")


def _reset_integer_sequences(connection: Connection, schema: str) -> None:
    if connection.dialect.name != "postgresql":
        return

    for table in Base.metadata.sorted_tables:
        primary_key = list(table.primary_key.columns)
        if len(primary_key) != 1 or not isinstance(primary_key[0].type, Integer):
            continue

        column = primary_key[0]
        sequence = connection.scalar(
            text("SELECT pg_get_serial_sequence(:table_name, :column_name)"),
            {
                "table_name": f"{schema}.{table.name}",
                "column_name": column.name,
            },
        )
        if not sequence:
            continue

        maximum = connection.scalar(select(func.max(column)))
        connection.execute(
            text(
                "SELECT setval(CAST(:sequence_name AS regclass), "
                ":sequence_value, :is_called)"
            ),
            {
                "sequence_name": sequence,
                "sequence_value": maximum if maximum is not None else 1,
                "is_called": maximum is not None,
            },
        )


def copy_all_tables(
    source_engine: Engine,
    destination_engine: Engine,
    *,
    destination_schema: str,
) -> dict[str, int]:
    copied: dict[str, int] = {}
    with source_engine.connect() as source, destination_engine.begin() as destination:
        for table in Base.metadata.sorted_tables:
            if destination.execute(select(table).limit(1)).first() is not None:
                copied[table.name] = 0
                print(f"  {table.name}: destination already contains data, skipping")
                continue

            rows = source.execute(select(table)).mappings().all()
            if rows:
                destination.execute(table.insert(), [dict(row) for row in rows])
            copied[table.name] = len(rows)
            print(f"  {table.name}: copied {len(rows)} rows")

        _reset_integer_sequences(destination, destination_schema)
    return copied


def main() -> None:
    source_url = normalize_database_url(os.environ["OLD_DATABASE_URL"])
    destination_url = normalize_database_url(os.environ["NEW_DATABASE_URL"])
    destination_schema = os.getenv("DESTINATION_SCHEMA", "gsatmax").strip()
    if not destination_schema:
        raise RuntimeError("DESTINATION_SCHEMA must not be empty.")

    source_engine = create_engine(source_url, connect_args=_connect_args(source_url))
    destination_engine = create_engine(
        destination_url,
        connect_args=_connect_args(destination_url),
    )
    try:
        _assert_destination_schema(destination_engine, destination_schema)
        _run_migrations(destination_url)
        copied = copy_all_tables(
            source_engine,
            destination_engine,
            destination_schema=destination_schema,
        )
    finally:
        source_engine.dispose()
        destination_engine.dispose()

    total = sum(copied.values())
    print(f"Done. Copied {total} rows across {len(copied)} tables.")


if __name__ == "__main__":
    main()
