"""The public web build must refuse an API base URL a visitor cannot reach.

``scripts/vercel_build_web.sh`` bakes ``API_BASE_URL`` into the Flutter bundle
with ``--dart-define``, so the value is fixed at build time and a wrong one
ships a site whose every request fails in the browser. Nothing else in the
pipeline catches that: ``lib/core/config/app_config.dart`` exempts ``localhost``
and ``127.0.0.1`` from its production HTTPS rule and falls back to
``http://localhost:8000`` when the define is blank, and the release preflight
only inspects the fallback literal in the build script rather than the value a
real Vercel build uses.

These tests drive ``scripts/check_api_base_url.sh`` directly. It takes one
argument and reads no environment variables, so no secret is involved.
"""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess

import pytest

from backend.release_preflight import shell_default

PROJECT_ROOT = Path(__file__).resolve().parents[2]
GUARD = PROJECT_ROOT / "scripts" / "check_api_base_url.sh"
BUILD_SCRIPT = PROJECT_ROOT / "scripts" / "vercel_build_web.sh"

BASH = shutil.which("bash")
requires_bash = pytest.mark.skipif(BASH is None, reason="bash is not on PATH")


def run_guard(value: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [BASH, str(GUARD), value],
        capture_output=True,
        text=True,
        cwd=PROJECT_ROOT,
    )


REACHABLE = (
    "https://gsat-max-api-lucas.onrender.com",
    "https://api.gsat-max.tw",
    "https://api.gsat-max.tw:8443",
    "  https://gsat-max-api-lucas.onrender.com  ",
)

UNREACHABLE = (
    # A blank value: AppConfig would fall back to http://localhost:8000.
    ("", "empty"),
    ("   ", "empty"),
    # vercel.json rewrites /(.*) to /index.html, so /api returns the SPA shell.
    ("/api", "same-origin path"),
    # Plaintext: blocked as mixed content on an HTTPS page.
    ("http://gsat-max-api-lucas.onrender.com", "https"),
    # Local endpoints -- the failure this guard exists for.
    ("http://localhost:8000", "local"),
    ("https://localhost:8000", "local"),
    ("https://127.0.0.1:8000", "local"),
    ("https://10.0.2.2:8000", "local"),
    ("https://192.168.1.10", "local"),
    ("https://[::1]:8000", "local"),
    # A compose service name resolves only inside the deployment network.
    ("https://backend", "publicly resolvable"),
    # Not a bare origin: AppConfig joins the base straight onto '/health'.
    ("https://api.gsat-max.tw/", "bare origin"),
    ("https://api.gsat-max.tw/api", "bare origin"),
    ("https://api.gsat-max.tw?token=x", "bare origin"),
    # Malformed values.
    ("https://", "no host"),
    ("https://not a host", "valid host"),
    ("gsat-max-api-lucas.onrender.com", "https"),
)


@requires_bash
@pytest.mark.parametrize("value", REACHABLE)
def test_a_public_https_origin_is_accepted(value: str) -> None:
    result = run_guard(value)
    assert result.returncode == 0, result.stderr


@requires_bash
@pytest.mark.parametrize("value, reason", UNREACHABLE)
def test_an_unreachable_backend_fails_the_build(value: str, reason: str) -> None:
    result = run_guard(value)
    assert result.returncode != 0, f"{value!r} was accepted: {result.stdout}"
    assert reason in result.stderr, result.stderr


@requires_bash
def test_the_build_scripts_own_fallback_passes_its_guard() -> None:
    fallback = shell_default(
        BUILD_SCRIPT.read_text(encoding="utf-8"), "API_BASE_URL"
    )
    assert fallback, "vercel_build_web.sh no longer declares an API_BASE_URL fallback"
    result = run_guard(fallback)
    assert result.returncode == 0, result.stderr


def test_the_public_build_runs_the_guard_before_compiling() -> None:
    """A guard the build script stopped calling would fail silently again."""
    lines = [
        line
        for line in BUILD_SCRIPT.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("#")
    ]
    guard_at = next(
        (i for i, line in enumerate(lines) if "check_api_base_url.sh" in line), None
    )
    build_at = next(
        (i for i, line in enumerate(lines) if "flutter build web" in line), None
    )
    assert guard_at is not None, "vercel_build_web.sh never invokes the guard"
    assert build_at is not None, "vercel_build_web.sh no longer builds the web app"
    assert guard_at < build_at, "the guard runs after the bundle is already compiled"


@requires_bash
@pytest.mark.parametrize(
    "value, must_not_leak",
    [
        ("https://svc:hunter2@api.gsat-max.tw", "hunter2"),
        ("https://api.gsat-max.tw?token=s3cr3t", "s3cr3t"),
        ("https://api.gsat-max.tw#s3cr3t", "s3cr3t"),
    ],
)
def test_the_rejection_message_keeps_credentials_out_of_the_build_log(
    value: str, must_not_leak: str
) -> None:
    """Vercel build logs are readable; a misconfigured URL must not seed them."""
    result = run_guard(value)
    assert result.returncode != 0, f"{value!r} was accepted"
    assert must_not_leak not in result.stdout + result.stderr
