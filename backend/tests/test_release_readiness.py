from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timedelta
import asyncio
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import uuid

from alembic import command as alembic_command
from alembic.config import Config as AlembicConfig
import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, func, select
from sqlalchemy.orm import Session

from backend import main as backend_main
from backend.main import PerformanceMetrics
from backend.models import (
    BackgroundJob,
    Base,
    DailyExpansionQuiz,
    GrammarErrorLedger,
    User,
)


PROJECT_ROOT = Path(__file__).resolve().parents[2]
OCR_FIXTURE = Path(__file__).resolve().parent / "fixtures" / "exam_sample.png"


def _metrics() -> PerformanceMetrics:
    return PerformanceMetrics(
        total_time_seconds=0.5,
        tokens_per_second=20,
        total_tokens=10,
    )


def test_logout_revokes_refresh_token(client: TestClient) -> None:
    email = f"logout-{uuid.uuid4().hex}@example.com"
    registered = client.post(
        "/auth/register",
        json={"email": email, "password": "logout-password-123"},
    )
    assert registered.status_code == 200, registered.text
    refresh_token = registered.json()["refresh_token"]

    logged_out = client.post(
        "/auth/logout",
        json={"refresh_token": refresh_token},
    )
    assert logged_out.status_code == 200
    assert logged_out.json() == {"status": "logged_out"}
    assert client.post(
        "/auth/refresh",
        json={"refresh_token": refresh_token},
    ).status_code == 401
    assert client.post(
        "/auth/logout",
        json={"refresh_token": refresh_token},
    ).status_code == 200


def test_ai_quota_blocks_free_user_and_pro_bypasses_deduction(
    client: TestClient,
    auth_session: dict[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user_id = int(auth_session["user_id"])
    headers = auth_session["headers"]
    with backend_main.SessionLocal() as db:
        user = db.get(User, user_id)
        assert user is not None
        user.is_pro = False
        user.daily_ai_quota = 0
        user.quota_reset_date = datetime.utcnow()
        db.commit()

    calls = 0

    async def fake_codex(*args: object, **kwargs: object):
        nonlocal calls
        calls += 1
        return json.dumps(
            {"etymology": "adapt + -able", "taiwanese_mnemonic": "可調整就能適應"}
        ), _metrics()

    monkeypatch.setattr(backend_main, "call_codex_api", fake_codex)
    blocked = client.post(
        "/generate/vocab-mnemonic",
        headers=headers,
        json={"word": "adaptable"},
    )
    assert blocked.status_code == 403
    assert blocked.json()["detail"] == "Daily AI generation limit reached."
    assert calls == 0

    with backend_main.SessionLocal() as db:
        user = db.get(User, user_id)
        assert user is not None
        user.is_pro = True
        user.daily_ai_quota = 0
        db.commit()

    allowed = client.post(
        "/generate/vocab-mnemonic",
        headers=headers,
        json={"word": "adaptable"},
    )
    assert allowed.status_code == 200, allowed.text
    assert allowed.json()["etymology"] == "adapt + -able"
    assert calls == 1
    with backend_main.SessionLocal() as db:
        user = db.get(User, user_id)
        assert user is not None
        assert user.daily_ai_quota == 0
        user.is_pro = False
        user.daily_ai_quota = 20
        db.commit()


def test_revenuecat_webhook_requires_secret_and_controls_entitlement(
    client: TestClient,
    auth_session: dict[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user_id = int(auth_session["user_id"])
    monkeypatch.setattr(
        backend_main,
        "settings",
        replace(backend_main.settings, revenuecat_webhook_auth="rc-test-secret"),
    )
    event = {"event": {"app_user_id": str(user_id), "type": "INITIAL_PURCHASE"}}
    assert client.post(
        "/integrations/revenuecat/webhook",
        headers={"Authorization": "Bearer wrong"},
        json=event,
    ).status_code == 401

    purchased = client.post(
        "/integrations/revenuecat/webhook",
        headers={"Authorization": "Bearer rc-test-secret"},
        json=event,
    )
    assert purchased.status_code == 200
    assert purchased.json()["status"] == "processed"
    with backend_main.SessionLocal() as db:
        assert db.get(User, user_id).is_pro is True

    expired = client.post(
        "/integrations/revenuecat/webhook",
        headers={"Authorization": "Bearer rc-test-secret"},
        json={"event": {"app_user_id": str(user_id), "type": "EXPIRATION"}},
    )
    assert expired.status_code == 200
    with backend_main.SessionLocal() as db:
        assert db.get(User, user_id).is_pro is False


def test_weekly_report_uses_persisted_mission_counts(
    client: TestClient,
    auth_session: dict[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_codex(*args: object, **kwargs: object):
        return "You completed real persisted missions this week.", _metrics()

    monkeypatch.setattr(backend_main, "call_codex_api", fake_codex)
    response = client.post(
        "/user/weekly-report",
        headers=auth_session["headers"],
        json={"persona": "Encouraging", "app_mode": "focus"},
    )
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["mission_tasks_total"] >= 1
    assert data["mission_tasks_completed"] >= 1
    assert data["mission_tasks_completed"] <= data["mission_tasks_total"]
    assert "persisted missions" in data["report"]


def test_background_job_retry_clears_error_and_enforces_limit(
    client: TestClient,
    auth_session: dict[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    user_id = int(auth_session["user_id"])
    job_id = uuid.uuid4().hex
    with backend_main.SessionLocal() as db:
        db.add(
            BackgroundJob(
                id=job_id,
                user_id=user_id,
                job_type="full_mock_exam",
                status="failed",
                payload_json="{}",
                error_message="temporary provider timeout",
                attempts=1,
                idempotency_key=f"retry-{job_id}",
            )
        )
        db.commit()

    monkeypatch.setattr(
        backend_main,
        "schedule_background_job",
        lambda background_tasks, job: None,
    )
    retried = client.post(f"/jobs/{job_id}/retry", headers=auth_session["headers"])
    assert retried.status_code == 200
    assert retried.json()["status"] == "queued"
    assert retried.json()["error_message"] is None

    with backend_main.SessionLocal() as db:
        job = db.get(BackgroundJob, job_id)
        assert job is not None
        job.status = "failed"
        job.attempts = 3
        db.commit()
    assert client.post(
        f"/jobs/{job_id}/retry",
        headers=auth_session["headers"],
    ).status_code == 409


def test_writing_endpoint_retries_then_rejects_malformed_ai(
    client: TestClient,
    auth_session: dict[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    attempts = 0

    async def malformed_ai(*args: object, **kwargs: object):
        nonlocal attempts
        attempts += 1
        return "Content 5, Grammar 5, Vocabulary 5", _metrics()

    monkeypatch.setattr(backend_main, "call_codex_api", malformed_ai)
    response = client.post(
        "/evaluate/writing",
        headers=auth_session["headers"],
        json={
            "essay": "Students should examine evidence carefully before making decisions.",
            "essay_type": "standard",
            "app_mode": "focus",
        },
    )
    assert response.status_code == 502
    assert "schema validation" in response.json()["detail"]
    assert attempts == 2


def test_real_tesseract_extracts_fixture_text() -> None:
    if not backend_main.settings.tesseract_cmd and not os.environ.get("CI"):
        pytest.skip("Tesseract is not installed in this developer environment.")
    extracted = backend_main.extract_text_from_image(OCR_FIXTURE.read_bytes())
    assert "Although the weather was bad" in extracted
    assert "Student answer" in extracted
    assert "scientist collected evidence" in extracted


def test_ocr_pipeline_persists_ledger_and_next_day_expansion(
    client: TestClient,
    auth_session: dict[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_vision(*args: object, **kwargs: object):
        return json.dumps(
            {
                "analysis": "1. Review conjunctions. 2. Compare clause structure. 3. Retry tomorrow.",
                "corrected_mistakes": [
                    {
                        "original_question": "Although the weather was bad, we continued.",
                        "student_wrong_answer": "Despite",
                        "correct_answer": "Although",
                        "explanation": "Although introduces a full clause; despite requires a noun phrase.",
                        "grammar_concept": "conjunctions",
                        "vocab_word": None,
                    }
                ],
            }
        ), _metrics()

    async def fake_codex(*args: object, **kwargs: object):
        return json.dumps(
            [
                {
                    "concept": "conjunctions",
                    "question": f"Expansion question {index}",
                    "options": ["although", "despite of", "because of", "therefore"],
                    "correct_option_index": 0,
                    "explanation": "Use although before a full clause.",
                }
                for index in range(1, 4)
            ]
        ), _metrics()

    monkeypatch.setattr(backend_main, "call_codex_vision_api", fake_vision)
    monkeypatch.setattr(backend_main, "call_codex_api", fake_codex)
    with OCR_FIXTURE.open("rb") as fixture:
        response = client.post(
            "/upload/exam/analyze-mistakes",
            headers=auth_session["headers"],
            files={"exam_image": ("exam_sample.png", fixture, "image/png")},
            data={"app_mode": "focus"},
        )
    assert response.status_code == 200, response.text
    data = response.json()
    assert "Although the weather was bad" in data["extracted_text"]
    assert len(data["corrected_mistakes"]) == 1
    job_id = data["expansion_job_id"]
    assert job_id

    job = client.get(f"/jobs/{job_id}", headers=auth_session["headers"])
    assert job.status_code == 200
    assert job.json()["status"] == "completed"
    assert job.json()["result"]["expansion_quiz_count"] == 3
    tomorrow = datetime.utcnow().date() + timedelta(days=1)
    with backend_main.SessionLocal() as db:
        ledger_id = data["corrected_mistakes"][0]["ledger_error_id"]
        ledger = db.get(GrammarErrorLedger, ledger_id)
        assert ledger is not None
        quizzes = db.scalars(
            select(DailyExpansionQuiz).where(
                DailyExpansionQuiz.source_job_id == job_id
            )
        ).all()
        assert len(quizzes) == 3
        assert all(quiz.due_date.date() == tomorrow for quiz in quizzes)
        assert db.scalar(
            select(func.count(DailyExpansionQuiz.id)).where(
                DailyExpansionQuiz.source_job_id == job_id
            )
        ) == 3


def test_alembic_clean_existing_and_downgrade_paths(tmp_path: Path) -> None:
    config_path = PROJECT_ROOT / "alembic.ini"
    clean_path = tmp_path / "clean.sqlite3"
    clean_url = f"sqlite:///{clean_path.as_posix()}"
    config = AlembicConfig(str(config_path))
    config.attributes["database_url"] = clean_url
    alembic_command.upgrade(config, "head")
    with sqlite3.connect(clean_path) as connection:
        assert connection.execute(
            "SELECT version_num FROM alembic_version"
        ).fetchone()[0] == "328de383cbc9"
        assert connection.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table'"
        ).fetchone()[0] == 17
    alembic_command.downgrade(config, "base")
    with sqlite3.connect(clean_path) as connection:
        remaining = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        assert remaining <= {"alembic_version"}

    existing_path = tmp_path / "existing.sqlite3"
    existing_engine = create_engine(f"sqlite:///{existing_path.as_posix()}")
    Base.metadata.create_all(existing_engine)
    with Session(existing_engine) as db:
        db.add(User(email="migration@example.com", display_name="Preserve Me"))
        db.commit()
    existing_config = AlembicConfig(str(config_path))
    existing_config.attributes["database_url"] = (
        f"sqlite:///{existing_path.as_posix()}"
    )
    alembic_command.upgrade(existing_config, "head")
    with sqlite3.connect(existing_path) as connection:
        assert connection.execute("SELECT COUNT(*) FROM users").fetchone()[0] == 1
        assert connection.execute(
            "SELECT version_num FROM alembic_version"
        ).fetchone()[0] == "328de383cbc9"
    existing_engine.dispose()


def test_seed_cli_reaches_target_and_is_idempotent(tmp_path: Path) -> None:
    database_path = tmp_path / "seed.sqlite3"
    command = [
        sys.executable,
        str(PROJECT_ROOT / "backend" / "seed_data.py"),
        "--vocab",
        "500",
        "--grammar",
        "50",
        "--batch-size",
        "50",
        "--offline-fallback",
        "--database-url",
        f"sqlite:///{database_path.as_posix()}",
    ]
    environment = {**os.environ, "OPENAI_API_KEY": ""}
    first = subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        env=environment,
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    )
    second = subprocess.run(
        command,
        cwd=PROJECT_ROOT,
        env=environment,
        check=True,
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert '"vocab_inserted": 500' in first.stdout
    assert '"grammar_concepts_inserted": 50' in first.stdout
    assert '"vocab_inserted": 0' in second.stdout
    assert '"grammar_concepts_inserted": 0' in second.stdout
    with sqlite3.connect(database_path) as connection:
        assert connection.execute("SELECT COUNT(*) FROM vocabulary").fetchone()[0] == 500
        assert connection.execute(
            "SELECT COUNT(*) FROM grammar_concept_bank"
        ).fetchone()[0] == 50


def test_openai_adapter_retries_transient_failures_and_reports_metrics(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    attempts = 0

    class FakeAsyncClient:
        def __init__(self, *args: object, **kwargs: object) -> None:
            pass

        async def __aenter__(self) -> "FakeAsyncClient":
            return self

        async def __aexit__(self, *args: object) -> None:
            return None

        async def post(self, url: str, **kwargs: object) -> httpx.Response:
            nonlocal attempts
            attempts += 1
            request = httpx.Request("POST", url)
            if attempts < 3:
                return httpx.Response(429, request=request, json={"error": "busy"})
            return httpx.Response(
                200,
                request=request,
                json={
                    "choices": [{"message": {"content": "verified output"}}],
                    "usage": {"total_tokens": 18},
                },
            )

    async def no_delay(_: float) -> None:
        return None

    monkeypatch.setattr(backend_main, "OPENAI_API_KEY", "test-secret-not-logged")
    monkeypatch.setattr(backend_main, "OPENAI_MAX_RETRIES", 3)
    monkeypatch.setattr(backend_main.httpx, "AsyncClient", FakeAsyncClient)
    monkeypatch.setattr(backend_main.asyncio, "sleep", no_delay)

    async def run_request() -> tuple[str, PerformanceMetrics]:
        return await backend_main.call_codex_api(
            "Return a concise answer.", app_mode="focus"
        )

    text, metrics = asyncio.run(run_request())
    assert attempts == 3
    assert text == "verified output"
    assert metrics.total_tokens == 18
    assert metrics.total_time_seconds >= 0
