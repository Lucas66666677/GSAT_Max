from pathlib import Path

from sqlalchemy import create_engine, select

from backend.config import normalize_database_url
from backend.migrate_database import copy_all_tables
from backend.models import Base, User


def _sqlite_engine(path: Path):
    return create_engine(
        f"sqlite:///{path.as_posix()}",
        connect_args={"check_same_thread": False},
    )


def test_provider_postgres_urls_select_psycopg_three() -> None:
    assert normalize_database_url("postgres://user:pass@db.example/app").startswith(
        "postgresql+psycopg://"
    )
    assert normalize_database_url("postgresql://user:pass@db.example/app").startswith(
        "postgresql+psycopg://"
    )


def test_copy_all_tables_is_fk_ordered_and_safe_to_rerun(tmp_path: Path) -> None:
    source = _sqlite_engine(tmp_path / "source.sqlite3")
    destination = _sqlite_engine(tmp_path / "destination.sqlite3")
    Base.metadata.create_all(source)
    Base.metadata.create_all(destination)

    with source.begin() as connection:
        connection.execute(
            User.__table__.insert().values(
                id=42,
                email="student@example.test",
                display_name="Student",
            )
        )

    first = copy_all_tables(source, destination, destination_schema="gsatmax")
    second = copy_all_tables(source, destination, destination_schema="gsatmax")

    assert first["users"] == 1
    assert second["users"] == 0
    with destination.connect() as connection:
        users = connection.execute(select(User)).scalars().all()
    assert users == [42]

    source.dispose()
    destination.dispose()
