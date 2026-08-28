"""The public web build must refuse an API base URL a visitor cannot reach.

``scripts/vercel_build_web.sh`` bakes ``API_BASE_URL`` into the Flutter bundle
with ``--dart-define``, so the value is fixed at build time and a wrong one
ships a site whose every request fails in the browser. Nothing else in the
pipeline catches that: ``lib/core/config/app_config.dart`` exempts ``localhost``
and ``127.0.0.1`` from its production HTTPS rule and falls back to
``http://localhost:8000`` when the define is blank, and the release preflight
only inspects the fallback literal in the build script rather than the value a
real Vercel build uses.

The same value must also name a *different* host from the site itself. The
backend is a separate deployment, so an ``API_BASE_URL`` pointing at the site's
own origin is answered by the ``vercel.json`` rewrite of ``/(.*)`` to
``/index.html``: ``/health`` returns 200 with the SPA shell in it, and the
client parses HTML as JSON. The guard already refuses the relative spelling of
that mistake (``/api``); these tests cover the absolute one, which passes every
other rule -- it is HTTPS, a bare origin, and publicly resolvable.

These tests drive ``scripts/check_api_base_url.sh`` directly. It takes
arguments and reads no environment variables, so no secret is involved.
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


def run_guard(value: str, *site_hosts: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [BASH, str(GUARD), value, *site_hosts],
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


# --------------------------------------------------------------------------- #
# The API origin must not be the site's own
# --------------------------------------------------------------------------- #

SITE = "https://gsat-max.example.com"


@requires_bash
@pytest.mark.parametrize(
    "api_base_url, site_host",
    [
        # The host as Vercel supplies it in VERCEL_URL: no scheme.
        (SITE, "gsat-max.example.com"),
        # PUBLIC_APP_URL spelling: a full origin, optionally with a slash.
        (SITE, SITE),
        (SITE, SITE + "/"),
        # Case is not significant in a host name.
        ("https://GSAT-MAX.example.com", "gsat-max.example.com"),
        ("https://gsat-max.example.com", "GSAT-Max.Example.COM"),
        # :443 is what https means; the two spell one origin.
        (SITE + ":443", "gsat-max.example.com"),
        (SITE, "gsat-max.example.com:443"),
    ],
)
def test_the_sites_own_origin_is_not_a_backend(
    api_base_url: str, site_host: str
) -> None:
    result = run_guard(api_base_url, site_host)
    assert result.returncode != 0, f"{api_base_url!r} was accepted: {result.stdout}"
    assert "own origin" in result.stderr, result.stderr
    assert "/index.html" in result.stderr, result.stderr


@requires_bash
def test_any_of_the_supplied_site_names_is_refused() -> None:
    """A Vercel build knows the site by its deployment URL and its domain."""
    for position in range(3):
        hosts = ["", "", ""]
        hosts[position] = "gsat-max.example.com"
        result = run_guard(SITE, *hosts)
        assert result.returncode != 0, f"accepted at position {position}"


@requires_bash
@pytest.mark.parametrize(
    "api_base_url, site_hosts",
    [
        # The real arrangement: a backend on its own host.
        ("https://gsat-max-api-lucas.onrender.com", ("gsat-max.example.com",)),
        (
            "https://gsat-max-api-lucas.onrender.com",
            ("gsat-max.example.com", "gsat-max-abc123.vercel.app", SITE),
        ),
        # A different port on the shared host is a different endpoint, and the
        # vercel.json rewrite does not answer it.
        ("https://gsat-max.example.com:8443", ("gsat-max.example.com",)),
        # A neighbouring subdomain is a separate host.
        ("https://api.gsat-max.example.com", ("gsat-max.example.com",)),
    ],
)
def test_a_separate_backend_is_still_accepted(
    api_base_url: str, site_hosts: tuple[str, ...]
) -> None:
    result = run_guard(api_base_url, *site_hosts)
    assert result.returncode == 0, result.stderr


@requires_bash
@pytest.mark.parametrize("site_hosts", [(), ("",), ("", "", "")])
def test_an_unknown_site_host_leaves_the_other_rules_intact(
    site_hosts: tuple[str, ...]
) -> None:
    """VERCEL_URL and PUBLIC_APP_URL may both be unset; builds must still run."""
    assert run_guard("https://gsat-max-api-lucas.onrender.com", *site_hosts).returncode == 0
    assert run_guard("http://gsat-max-api-lucas.onrender.com", *site_hosts).returncode != 0
    assert run_guard("", *site_hosts).returncode != 0


@requires_bash
def test_the_site_comparison_keeps_credentials_out_of_the_build_log() -> None:
    result = run_guard("https://svc:hunter2@gsat-max.example.com", SITE)
    assert result.returncode != 0
    assert "hunter2" not in result.stdout + result.stderr


def test_the_public_build_tells_the_guard_which_host_is_the_site() -> None:
    """Without the site's own names the guard cannot make the comparison."""
    source = BUILD_SCRIPT.read_text(encoding="utf-8")
    invocation = next(
        line
        for line in source.splitlines()
        if "check_api_base_url.sh" in line and not line.lstrip().startswith("#")
    )
    assert "SITE_HOSTS" in invocation, invocation
    for name in ("VERCEL_PROJECT_PRODUCTION_URL", "VERCEL_URL", "PUBLIC_APP_URL"):
        assert f'"${{{name}:-}}"' in source, f"{name} is not passed to the guard"
