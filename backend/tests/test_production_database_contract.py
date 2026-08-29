"""Production must not report itself ready while running on a container-local file.

``load_settings`` falls back to ``sqlite:///backend/gsat_english.db`` when
``DATABASE_URL`` is unset, and that fallback is silent. Before this contract
existed, a service started with ``APP_ENV=production`` and no ``DATABASE_URL``
-- or with the value ``.env.example`` documents, which is that same SQLite path
-- passed :meth:`Settings.validate`, booted, ran its migrations against the
file, and answered::

    {"status": "ok", "environment": "production", "database": "reachable", ...}

Every one of those fields is true. The database *is* reachable. It is also
destroyed by the next deploy and invisible to a second replica, so the release
signal said ready while the production database did not exist.

``release_preflight`` already knew this: ``database_url_is_durable_postgres``
is one of its configuration-shape checks. But the preflight is a script someone
remembers to run, is not a step in ``.github/workflows/ci.yml``, and takes a
*description* of the environment rather than reading the deployment. The rule
therefore has to live where the deployment cannot skip it -- in the validator
the process runs on the way up -- and the two have to agree, which is what
``test_the_boot_gate_and_the_release_preflight_agree`` below asserts.

These checks construct settings objects and call the validator. No database is
opened, no network request is made, and no credential appears in any assertion.
"""

from __future__ import annotations

from dataclasses import replace

import pytest

from backend.config import (
    PROJECT_ROOT,
    Settings,
    is_durable_database_url,
    load_settings,
)
from backend.release_preflight import DatabaseUrlShape, parse_env_file


PRODUCTION_ORIGIN = "https://gsat-max.example.com"

#: Credential-free on purpose: nothing in this file needs a password to be a
#: realistic URL, and a sentinel password would only be a value to leak.
DURABLE_URL = "postgresql+psycopg://gsatmax@db.internal.example:5432/gsatmax"

#: Every other production rule satisfied, so a failure here is unambiguously
#: the database rule and not a bystander.
def _production_settings(database_url: str) -> Settings:
    return replace(
        load_settings(),
        app_env="production",
        database_url=database_url,
        cors_origins=(PRODUCTION_ORIGIN,),
        jwt_secret_key="p" * 48,
        public_app_url=PRODUCTION_ORIGIN,
        email_provider="resend",
        revenuecat_webhook_auth="webhook-shared-secret",
        max_upload_bytes=10_485_760,
    )


#: URLs that name a database outliving the container. The scheme is not the
#: point -- the host is.
DURABLE_URLS = (
    DURABLE_URL,
    "postgresql+psycopg://gsatmax@10.0.0.5:5432/gsatmax",
    "postgresql://db.internal.example/gsatmax",
    "mysql+pymysql://app@db.internal.example:3306/gsatmax",
)

#: URLs that name a file inside the container, or name no host at all.
CONTAINER_LOCAL_URLS = (
    "sqlite:///./backend/gsat_english.db",
    "sqlite:////var/lib/gsat/gsat_english.db",
    "sqlite+pysqlite:///./backend/gsat_english.db",
    "sqlite://",
    "postgresql+psycopg:///gsatmax",
)


@pytest.mark.parametrize("database_url", CONTAINER_LOCAL_URLS)
def test_production_refuses_a_container_local_database(database_url: str) -> None:
    """Fail closed on the way up, rather than serving a green /health."""

    with pytest.raises(RuntimeError, match="durable networked"):
        _production_settings(database_url).validate()


@pytest.mark.parametrize("database_url", DURABLE_URLS)
def test_production_accepts_a_networked_database(database_url: str) -> None:
    """Guards the guard: the rule has to be passable, not merely strict."""

    _production_settings(database_url).validate()


def test_the_unset_default_is_the_configuration_this_rule_exists_for() -> None:
    """The trap is that omitting DATABASE_URL is not an error, it is SQLite.

    ``load_settings`` supplies the development file as the default, so the
    failure mode is a variable nobody set rather than one somebody set wrongly.
    """

    default_url = load_settings().database_url
    assert not is_durable_database_url(default_url)

    with pytest.raises(RuntimeError, match="durable networked"):
        _production_settings(default_url).validate()


def test_the_documented_default_would_be_rejected_in_production() -> None:
    """`.env.example` documents the SQLite path, and it is copied.

    If this ever fails because `.env.example` gained a networked URL, the file
    has stopped being a development template -- fix the template rather than
    this test.
    """

    documented = parse_env_file(PROJECT_ROOT / ".env.example").get("DATABASE_URL")
    assert documented, ".env.example no longer documents DATABASE_URL"
    assert not is_durable_database_url(documented)


def test_non_production_environments_keep_sqlite() -> None:
    """Development, test and staging are unaffected by this rule.

    The suite itself runs on SQLite (`conftest.py`), and the deployed service
    currently reports `APP_ENV=staging`. Neither may be broken by a rule about
    production.
    """

    for app_env in ("development", "test", "staging"):
        replace(
            load_settings(),
            app_env=app_env,
            database_url="sqlite:///./backend/gsat_english.db",
        ).validate()


@pytest.mark.parametrize("database_url", DURABLE_URLS + CONTAINER_LOCAL_URLS)
def test_the_boot_gate_and_the_release_preflight_agree(database_url: str) -> None:
    """Two copies of one requirement, in two files, edited independently.

    ``release_preflight`` reduces the URL to a credential-free shape before
    judging it; ``config`` judges the URL itself. They must still reach the
    same verdict, or a release passes the preflight and then fails to boot --
    or, worse, passes the boot gate having been cleared by a preflight that
    was applying a laxer rule.
    """

    shape = DatabaseUrlShape.parse(database_url)
    preflight_verdict = bool(shape.present and not shape.is_sqlite and shape.host)

    assert is_durable_database_url(database_url) is preflight_verdict


def test_a_reachable_database_is_not_a_durable_one() -> None:
    """Why `/health` cannot be the gate that catches this.

    ``health_check`` runs ``SELECT 1`` and reports ``"database": "reachable"``.
    A container-local SQLite file answers that query, so the readiness payload
    is identical either way. Readiness measures reachability; durability is a
    configuration property, and only configuration validation can see it.
    """

    assert is_durable_database_url("sqlite:///./backend/gsat_english.db") is False
    assert is_durable_database_url(DURABLE_URL) is True
