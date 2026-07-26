from __future__ import annotations

import os
import tempfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient


TEST_DB_PATH = Path(tempfile.gettempdir()) / "gsat_max_backend_tests.sqlite3"
if TEST_DB_PATH.exists():
    TEST_DB_PATH.unlink()

os.environ["APP_ENV"] = "test"
os.environ["DATABASE_URL"] = f"sqlite:///{TEST_DB_PATH.as_posix()}"
os.environ["JWT_SECRET_KEY"] = "test-only-secret-key-with-more-than-32-characters"
os.environ["OPENAI_API_KEY"] = ""

from backend.main import app, engine  # noqa: E402


@pytest.fixture(scope="session")
def client() -> TestClient:
    with TestClient(app) as test_client:
        yield test_client
    engine.dispose()
    TEST_DB_PATH.unlink(missing_ok=True)


@pytest.fixture(scope="session")
def auth_session(client: TestClient) -> dict[str, object]:
    response = client.post(
        "/auth/register",
        json={
            "email": "integration.student@example.com",
            "password": "strong-password-123",
            "display_name": "Integration Student",
        },
    )
    assert response.status_code == 200, response.text
    data = response.json()
    return {
        "access_token": data["access_token"],
        "refresh_token": data["refresh_token"],
        "headers": {"Authorization": f"Bearer {data['access_token']}"},
        "user_id": data["user_id"],
    }
