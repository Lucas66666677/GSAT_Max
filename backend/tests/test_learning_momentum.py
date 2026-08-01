from __future__ import annotations

import asyncio
import uuid

import httpx
from fastapi.testclient import TestClient
import pytest

from backend import main as backend_main


def _register(client: TestClient) -> dict[str, str]:
    response = client.post(
        "/auth/register",
        json={
            "email": f"momentum-{uuid.uuid4().hex}@example.com",
            "password": "momentum-password-123",
            "display_name": "Momentum Student",
        },
    )
    assert response.status_code == 200, response.text
    data = response.json()
    return {"Authorization": f"Bearer {data['access_token']}"}


def test_time_budget_preferences_reward_and_replan_are_real_behaviors(
    client: TestClient,
) -> None:
    headers = _register(client)
    defaults = client.get("/user/learning-preferences", headers=headers)
    assert defaults.status_code == 200, defaults.text
    assert defaults.json()["weekday_minutes"] == 10
    assert defaults.json()["gentle_streak_enabled"] is True

    updated = client.put(
        "/user/learning-preferences",
        headers=headers,
        json={
            "weekday_minutes": 7,
            "weekend_minutes": 18,
            "preferred_session_minutes": 10,
            "weekly_goal_days": 4,
            "gentle_streak_enabled": True,
            "paper_pack_enabled": True,
        },
    )
    assert updated.status_code == 200, updated.text
    assert updated.json()["weekly_goal_days"] == 4

    rescue = client.post(
        "/user/daily-schedule/replan",
        headers=headers,
        json={"available_minutes": 3},
    )
    assert rescue.status_code == 200, rescue.text
    rescue_data = rescue.json()
    assert rescue_data["available_minutes"] == 3
    assert rescue_data["planned_minutes"] <= 3
    assert rescue_data["can_stop_when_complete"] is True
    assert rescue_data["tasks"][0]["type"] == "micro_win"
    assert rescue_data["tasks"][0]["success_target"] >= 0.9

    task = rescue_data["tasks"][0]
    completed = client.patch(
        f"/user/daily-schedule/tasks/{task['id']}",
        headers=headers,
        json={"completed": True},
    )
    assert completed.status_code == 200, completed.text
    assert completed.json()["reward"]["awarded"] is True
    assert completed.json()["reward"]["points"] == task["reward_points"]

    repeated = client.patch(
        f"/user/daily-schedule/tasks/{task['id']}",
        headers=headers,
        json={"completed": True},
    )
    assert repeated.status_code == 200
    assert repeated.json()["reward"]["awarded"] is False

    sprint = client.post(
        "/user/daily-schedule/replan",
        headers=headers,
        json={"available_minutes": 20},
    )
    assert sprint.status_code == 200, sprint.text
    sprint_data = sprint.json()
    assert sprint_data["planned_minutes"] <= 20
    preserved = next(item for item in sprint_data["tasks"] if item["id"] == task["id"])
    assert preserved["status"] == "completed"
    assert sprint_data["reward_summary"]["total_points"] == task["reward_points"]
    assert sprint_data["reward_summary"]["weekly_active_days"] == 1


def test_weekly_print_pack_pdf_completion_and_idempotency(
    client: TestClient,
) -> None:
    headers = _register(client)
    added = client.post(
        "/vocab/add",
        headers=headers,
        json={
            "word": "resilient",
            "definition": "有韌性的",
            "source_context": "A resilient learner returns after a difficult day.",
        },
    )
    assert added.status_code == 200, added.text
    ledger = client.post(
        "/grammar/error-ledger",
        headers=headers,
        json={
            "error_type": "subject_verb_agreement",
            "original_sentence": "Each student have a plan.",
            "user_answer": "have",
            "corrected_sentence": "Each student has a plan.",
            "explanation": "Each is singular.",
        },
    )
    assert ledger.status_code == 200, ledger.text

    created = client.post(
        "/user/weekly-study-pack",
        headers=headers,
        json={"daily_minutes": 10},
    )
    assert created.status_code == 200, created.text
    pack = created.json()
    assert len(pack["pack_code"]) == 8
    assert pack["day_count"] == 5
    assert pack["completed_days"] == []

    repeated = client.post(
        "/user/weekly-study-pack",
        headers=headers,
        json={"daily_minutes": 10},
    )
    assert repeated.status_code == 200
    assert repeated.json()["id"] == pack["id"]
    assert repeated.json()["pack_code"] == pack["pack_code"]

    pdf = client.get(
        f"/user/weekly-study-pack/{pack['id']}/pdf",
        headers=headers,
    )
    assert pdf.status_code == 200, pdf.text
    assert pdf.headers["content-type"].startswith("application/pdf")
    assert pdf.content.startswith(b"%PDF")
    assert len(pdf.content) > 4_000
    assert b"/FontFile2" in pdf.content
    assert b"MSung-Light" not in pdf.content

    completion = client.post(
        "/user/weekly-study-pack/complete",
        headers=headers,
        json={"pack_code": pack["pack_code"], "completed_days": [1, 2]},
    )
    assert completion.status_code == 200, completion.text
    assert completion.json()["pack"]["completed_days"] == [1, 2]
    assert completion.json()["reward"]["points"] == 28
    assert completion.json()["reward"]["awarded"] is True

    duplicate = client.post(
        "/user/weekly-study-pack/complete",
        headers=headers,
        json={"pack_code": pack["pack_code"], "completed_days": [1, 2]},
    )
    assert duplicate.status_code == 200
    assert duplicate.json()["reward"]["awarded"] is False
    assert duplicate.json()["reward"]["points"] == 0

    regenerated = client.post(
        "/user/weekly-study-pack",
        headers=headers,
        json={"daily_minutes": 20, "regenerate": True},
    )
    assert regenerated.status_code == 200
    assert regenerated.json()["completed_days"] == [1, 2]


def test_ai_router_falls_back_without_leaking_credentials(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    requests: list[tuple[str, str]] = []

    class FakeAsyncClient:
        def __init__(self, *args: object, **kwargs: object) -> None:
            pass

        async def __aenter__(self) -> "FakeAsyncClient":
            return self

        async def __aexit__(self, *args: object) -> None:
            return None

        async def post(self, url: str, **kwargs: object) -> httpx.Response:
            headers = kwargs.get("headers") or {}
            authorization = str(headers.get("Authorization", ""))
            requests.append((url, authorization))
            request = httpx.Request("POST", url)
            if "googleapis" in url:
                return httpx.Response(503, request=request, json={"error": "busy"})
            return httpx.Response(
                200,
                request=request,
                json={
                    "choices": [{"message": {"content": "fallback worked"}}],
                    "usage": {"total_tokens": 12},
                },
            )

    monkeypatch.setattr(backend_main, "AI_PROVIDER_ORDER", ("gemini", "groq"))
    monkeypatch.setattr(backend_main, "GEMINI_API_KEY", "gemini-test-secret")
    monkeypatch.setattr(backend_main, "GROQ_API_KEY", "groq-test-secret")
    monkeypatch.setattr(backend_main, "OPENAI_API_KEY", None)
    monkeypatch.setattr(backend_main, "OPENAI_MAX_RETRIES", 1)
    monkeypatch.setattr(backend_main.httpx, "AsyncClient", FakeAsyncClient)

    text_value, metrics = asyncio.run(
        backend_main.call_codex_api(
            "Student email: learner@example.com. Give one hint.",
            app_mode="focus",
        )
    )
    assert text_value == "fallback worked"
    assert metrics.provider == "groq"
    assert metrics.model == backend_main.GROQ_MODEL
    assert len(requests) == 2
    assert "googleapis" in requests[0][0]
    assert "api.groq.com" in requests[1][0]
    assert requests[0][1] == "Bearer gemini-test-secret"
    assert requests[1][1] == "Bearer groq-test-secret"


def test_student_pii_redaction_covers_common_identifiers() -> None:
    value = backend_main.redact_student_pii(
        "Name: Lin Yu Ting\nlearner@example.com\n0912-345-678\nA123456789"
    )
    assert "Lin Yu Ting" not in value
    assert "learner@example.com" not in value
    assert "0912-345-678" not in value
    assert "A123456789" not in value
    assert "[REDACTED_EMAIL]" in value
