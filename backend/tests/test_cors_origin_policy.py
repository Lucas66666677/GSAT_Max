"""Production must not hand CORS credentials to a non-public origin.

``API_CORS_ORIGINS`` entries reach the browser as ``Access-Control-Allow-Origin``.
A loopback, private, or link-local entry is either a development leftover or a
name that only resolves inside the deployment's network, so production rejects
it even when it is spelled with HTTPS.
"""

from __future__ import annotations

from dataclasses import replace

import pytest

from backend.config import Settings, is_public_origin, load_settings


PUBLIC_ORIGIN = "https://gsat-max.example.com"


def _production_settings(*origins: str) -> Settings:
    return replace(
        load_settings(),
        app_env="production",
        cors_origins=origins,
        # Production also requires a durable database; the suite runs on
        # SQLite. See test_production_database_contract.py.
        database_url="postgresql+psycopg://gsatmax@db.internal.example:5432/gsatmax",
        jwt_secret_key="p" * 48,
        public_app_url=PUBLIC_ORIGIN,
        email_provider="resend",
        revenuecat_webhook_auth="webhook-shared-secret",
        max_upload_bytes=10_485_760,
    )


@pytest.mark.parametrize(
    "origin",
    [
        "https://localhost",
        "https://localhost:8443",
        "https://api.localhost",
        "https://127.0.0.1:8443",
        "https://127.1.2.3",
        "https://[::1]",
        "https://10.0.0.5",
        "https://172.16.4.9",
        "https://192.168.1.10",
        "https://169.254.13.7",
        "https://[fd00::1]",
        "https://[fe80::1]",
        "https://[::ffff:10.0.0.5]",
    ],
)
def test_non_public_origins_are_rejected(origin: str) -> None:
    assert is_public_origin(origin) is False

    with pytest.raises(RuntimeError, match="loopback, private, or link-local"):
        _production_settings(PUBLIC_ORIGIN, origin).validate()


@pytest.mark.parametrize(
    "origin",
    [
        PUBLIC_ORIGIN,
        "https://gsat-max.example.com:8443",
        "https://8.8.8.8",
        "https://[2606:4700:4700::1111]",
    ],
)
def test_public_origins_are_accepted(origin: str) -> None:
    assert is_public_origin(origin) is True

    _production_settings(origin).validate()


def test_development_keeps_its_loopback_origins() -> None:
    settings = replace(
        load_settings(),
        app_env="development",
        cors_origins=("http://localhost:3000", "http://127.0.0.1:5173"),
    )

    settings.validate()
