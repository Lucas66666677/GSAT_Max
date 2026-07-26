from __future__ import annotations

from dataclasses import replace
from datetime import datetime, timedelta
import json

import pytest
from fastapi.testclient import TestClient

from backend.main import (
    FullMockExamResponse,
    PerformanceMetrics,
    calculate_sm2,
    parse_writing_evaluation,
    sanitize_full_mock_exam_for_client,
)
from backend import main as backend_main
from backend.models import MockExamSet


def test_health_and_protected_boundary(client: TestClient) -> None:
    health = client.get("/health")
    assert health.status_code == 200
    assert health.json()["status"] == "ok"
    assert client.get("/auth/me").status_code == 401
    assert client.get("/vocab/review").status_code == 401


def test_auth_refresh_rotation_and_client_upgrade_rejection(
    client: TestClient,
    auth_session: dict[str, object],
) -> None:
    headers = auth_session["headers"]
    me = client.get("/auth/me", headers=headers)
    assert me.status_code == 200
    assert me.json()["email"] == "integration.student@example.com"

    refresh_token = str(auth_session["refresh_token"])
    refreshed = client.post("/auth/refresh", json={"refresh_token": refresh_token})
    assert refreshed.status_code == 200
    assert refreshed.json()["refresh_token"] != refresh_token
    assert client.post("/auth/refresh", json={"refresh_token": refresh_token}).status_code == 401

    assert client.post("/user/upgrade", headers=headers).status_code == 403


def test_email_verification_and_password_reset(
    client: TestClient,
    auth_session: dict[str, object],
) -> None:
    headers = auth_session["headers"]
    verification = client.post("/auth/email-verification/request", headers=headers)
    assert verification.status_code == 200, verification.text
    verification_token = verification.json()["debug_token"]
    assert verification_token
    confirmed = client.post(
        "/auth/email-verification/confirm",
        json={"token": verification_token},
    )
    assert confirmed.status_code == 200
    assert confirmed.json()["email_verified"] is True

    reset = client.post(
        "/auth/password-reset/request",
        json={"email": "integration.student@example.com"},
    )
    assert reset.status_code == 200
    reset_token = reset.json()["debug_token"]
    changed = client.post(
        "/auth/password-reset/confirm",
        json={"token": reset_token, "new_password": "new-strong-password-456"},
    )
    assert changed.status_code == 200
    assert client.post(
        "/auth/login",
        json={
            "email": "integration.student@example.com",
            "password": "strong-password-123",
        },
    ).status_code == 401
    assert client.post(
        "/auth/login",
        json={
            "email": "integration.student@example.com",
            "password": "new-strong-password-456",
        },
    ).status_code == 200


def test_daily_mission_persistence_and_target_date(
    client: TestClient,
    auth_session: dict[str, object],
) -> None:
    headers = auth_session["headers"]
    first = client.get("/user/daily-schedule", headers=headers)
    assert first.status_code == 200, first.text
    first_data = first.json()
    assert first_data["tasks"]

    task = first_data["tasks"][0]
    updated = client.patch(
        f"/user/daily-schedule/tasks/{task['id']}",
        headers=headers,
        json={"completed": True},
    )
    assert updated.status_code == 200
    assert updated.json()["status"] == "completed"

    persisted = client.get("/user/daily-schedule", headers=headers).json()
    persisted_task = next(item for item in persisted["tasks"] if item["id"] == task["id"])
    assert persisted_task["status"] == "completed"

    target = datetime.utcnow() + timedelta(days=150)
    changed = client.patch(
        "/user/target-exam-date",
        headers=headers,
        json={"target_exam_date": target.isoformat()},
    )
    assert changed.status_code == 200, changed.text
    assert 149 <= changed.json()["days_remaining"] <= 150


def test_vocab_add_and_due_review(
    client: TestClient,
    auth_session: dict[str, object],
) -> None:
    headers = auth_session["headers"]
    added = client.post(
        "/vocab/add",
        headers=headers,
        json={
            "word": "Meticulous",
            "definition": "一絲不苟的",
            "source_context": "A meticulous student checks every answer.",
        },
    )
    assert added.status_code == 200, added.text
    assert added.json()["word"] == "meticulous"

    review = client.get("/vocab/review", headers=headers)
    assert review.status_code == 200
    assert any(item["word"] == "meticulous" for item in review.json())

    action = {
        "vocab_id": added.json()["vocab_id"],
        "quality": 4,
        "action_id": "review-action-idempotency-0001",
    }
    first_update = client.post("/vocab/update_progress", headers=headers, json=action)
    repeated_update = client.post("/vocab/update_progress", headers=headers, json=action)
    assert first_update.status_code == 200
    assert repeated_update.status_code == 200
    assert repeated_update.json() == first_update.json()


def test_ocr_upload_rejects_spoofed_mime_before_processing(
    client: TestClient,
    auth_session: dict[str, object],
) -> None:
    response = client.post(
        "/upload/exam",
        headers=auth_session["headers"],
        files={"exam_image": ("paper.txt", b"not-an-image", "text/plain")},
    )
    assert response.status_code == 415


def test_ocr_upload_rejects_files_over_configured_limit(
    client: TestClient,
    auth_session: dict[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(
        backend_main,
        "settings",
        replace(backend_main.settings, max_upload_bytes=1024),
    )
    oversized_png = b"\x89PNG\r\n\x1a\n" + (b"0" * 1025)
    response = client.post(
        "/upload/exam",
        headers=auth_session["headers"],
        files={"exam_image": ("large.png", oversized_png, "image/png")},
    )
    assert response.status_code == 413
    assert "exceeds" in response.json()["detail"].lower()


def test_sm2_updates_and_validation() -> None:
    first = calculate_sm2(quality=5, interval=0, repetitions=0, ease_factor=2.5)
    assert first["interval"] == 1
    assert first["repetitions"] == 1
    assert first["ease_factor"] > 2.5
    assert first["next_review_date"] > datetime.utcnow()

    failed = calculate_sm2(quality=1, interval=8, repetitions=3, ease_factor=2.2)
    assert failed["interval"] == 1
    assert failed["repetitions"] == 0
    with pytest.raises(ValueError):
        calculate_sm2(quality=6, interval=0, repetitions=0, ease_factor=2.5)


def test_writing_schema_parser_rejects_unstructured_scores() -> None:
    valid = """{
      "total_score": 15.5,
      "max_score": 20,
      "scores": {"content": 4, "organization": 4, "grammar": 3.5, "vocabulary": 4},
      "spelling_and_punctuation_issues": [],
      "corrections": [],
      "strengths": ["Clear position"],
      "priority_improvements": ["Use a more specific example"],
      "suggested_template": ["State the claim", "Support it", "Conclude"],
      "advanced_vocabulary_alternatives": [],
      "demonstration": "A concise model paragraph.",
      "rubric_version": "gsat-writing-v1"
    }"""
    evaluation = parse_writing_evaluation(valid)
    assert evaluation.total_score == 15.5
    assert evaluation.scores.grammar == 3.5
    with pytest.raises(Exception):
        parse_writing_evaluation("Content 5, Grammar 5, Vocabulary 5")


def test_mock_exam_client_payload_does_not_reveal_answers() -> None:
    response = FullMockExamResponse(
        exam_id="exam-test",
        title="GSAT Test",
        generated_at=datetime.utcnow(),
        sections=[
            {
                "title": "Vocabulary",
                "questions": [
                    {
                        "number": 1,
                        "stem": "Choose one.",
                        "options": ["A", "B", "C", "D"],
                        "correct_option_index": 2,
                        "explanation": "C is correct.",
                    }
                ],
            }
        ],
        non_choice={},
        performance_metrics=PerformanceMetrics(
            total_time_seconds=1.0,
            tokens_per_second=10.0,
            total_tokens=10,
        ),
    )
    sanitized = sanitize_full_mock_exam_for_client(response)
    question = sanitized.sections[0]["questions"][0]
    assert "correct_option_index" not in question
    assert "explanation" not in question


def test_mock_exam_grading_uses_server_answer_key(
    client: TestClient,
    auth_session: dict[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    exam_id = "authoritative-exam-test"
    stored_payload = {
        "exam_id": exam_id,
        "title": "Authoritative Test",
        "generated_at": datetime.utcnow().isoformat(),
        "sections": [
            {
                "title": "Vocabulary",
                "questions": [
                    {
                        "number": 1,
                        "stem": "Choose one.",
                        "options": ["A", "B", "C", "D"],
                        "correct_option_index": 2,
                    }
                ],
            }
        ],
        "non_choice": {
            "translation": {"zh_to_en": "測試"},
            "essay": {"prompt": "Write an essay."},
        },
        "performance_metrics": {
            "total_time_seconds": 0,
            "tokens_per_second": 0,
            "total_tokens": 0,
            "cached": False,
        },
    }
    with backend_main.SessionLocal() as db:
        db.add(
            MockExamSet(
                id=exam_id,
                user_id=int(auth_session["user_id"]),
                version="test-v1",
                difficulty="GSAT",
                payload_json=json.dumps(stored_payload),
            )
        )
        db.commit()

    async def fake_ai(*args: object, **kwargs: object):
        return (
            json.dumps(
                {
                    "translation_score": 8,
                    "essay_score": 16,
                    "translation_feedback": "Accurate overall.",
                    "essay_feedback": "Well organized.",
                    "priority_improvements": ["Use more precise evidence."],
                    "rubric_version": "gsat-mock-v1",
                }
            ),
            PerformanceMetrics(
                total_time_seconds=1,
                tokens_per_second=20,
                total_tokens=20,
            ),
        )

    monkeypatch.setattr(backend_main, "call_codex_api", fake_ai)
    graded = client.post(
        "/evaluate/full-mock-exam",
        headers=auth_session["headers"],
        json={
            "exam_id": exam_id,
            "selected_answers": {"1": 2},
            "translation_answer": "This is a test.",
            "essay_answer": "An original student essay.",
        },
    )
    assert graded.status_code == 200, graded.text
    data = graded.json()
    assert data["objective_correct"] == 1
    assert data["objective_score"] == 70
    assert data["total_score"] == 94


def test_full_mock_exam_background_job_status_and_idempotency(
    client: TestClient,
    auth_session: dict[str, object],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    async def fake_generation(*args: object, **kwargs: object) -> FullMockExamResponse:
        return FullMockExamResponse(
            exam_id="background-exam-result",
            title="Background GSAT",
            generated_at=datetime.utcnow(),
            sections=[{"title": "Vocabulary", "questions": []}],
            non_choice={},
            performance_metrics=PerformanceMetrics(
                total_time_seconds=0.5,
                tokens_per_second=20,
                total_tokens=10,
            ),
        )

    monkeypatch.setattr(backend_main, "generate_full_mock_exam", fake_generation)
    payload = {
        "difficulty": "GSAT",
        "version": "background-test-v1",
        "app_mode": "focus",
    }
    queued = client.post(
        "/generate/full-mock-exam/jobs",
        headers=auth_session["headers"],
        json=payload,
    )
    assert queued.status_code == 202, queued.text
    job_id = queued.json()["id"]
    status = client.get(f"/jobs/{job_id}", headers=auth_session["headers"])
    assert status.status_code == 200
    assert status.json()["status"] == "completed"
    assert status.json()["result"]["exam_id"] == "background-exam-result"

    repeated = client.post(
        "/generate/full-mock-exam/jobs",
        headers=auth_session["headers"],
        json=payload,
    )
    assert repeated.status_code == 202
    assert repeated.json()["id"] == job_id
