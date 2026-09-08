"""The deployed revision is publishable; the variable it comes from is not.

Nothing this service serves says which commit is running. ``/health`` reports
``environment`` and a provider list, which describe the configuration, not the
build -- so a release that changed only behaviour is indistinguishable from one
that never deployed, and the only way the question has been answered is by
finding a behavioural difference between two releases. That works once per
release, and not at all for the release where it matters most: a merge CI
passed and the platform may or may not have picked up.

``GET /version`` answers it from ``RENDER_GIT_COMMIT``. Two properties are
worth stating as tests, because neither is visible in the handler:

1. **Only hexadecimal can be published.** The route is unauthenticated, and the
   failure mode of an environment variable is holding the wrong thing -- a
   database URL, an API key, a pasted ``.env`` line. A presence or length check
   would return every one of those to an anonymous caller, so
   ``config.commit_sha_or_none`` is a whitelist and the checks below drive real
   secret shapes through it.

2. **The existing health contracts did not move.** This is a third route rather
   than a field on ``/health`` precisely because ``release_preflight`` pins
   ``/health``'s field set exactly and the deployment gate probes ``/livez``'s
   literal payload. The checks at the end fail if either grows a revision.

The release preflight is extended in step with this, and the last group here
asserts that extension actually rejects a leaky payload rather than passing
whatever it is shown. No database is opened, no network request is made, and no
credential appears in any assertion.
"""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import ast

from fastapi.testclient import TestClient
import pytest

from backend import main as backend_main
from backend.config import (
    PROJECT_ROOT,
    REVISION_ENV_VAR,
    commit_sha_or_none,
    load_settings,
)
from backend.release_preflight import (
    PLATFORM_ENV_KEYS,
    VERSION_PAYLOAD_EXPRESSION,
    VERSION_ROUTE,
    check_health_contract,
    health_payload_sources,
    parse_env_file,
)


#: A real 40-character SHA-1, in the shape Render injects.
A_COMMIT_SHA = "b9254220e7c1a83f45d6b0e29fc7a418d35e0c6b"

DEPLOYMENT_DOC = PROJECT_ROOT / "docs" / "WEB_DEPLOYMENT.md"

#: What an environment variable holds when someone fills in the wrong box, or
#: when a platform substitutes something unexpected. Every one is truthy, so a
#: presence check would publish all of them.
NOT_A_COMMIT_SHA = [
    "postgresql+psycopg://gsatmax:hunter2@db.internal.example:5432/gsatmax",
    "sk-proj-Ab3dEf9GhJkLmNpQrStUvWxYz0123456789",
    "gsk_Ab3dEf9GhJkLmNpQrStUvWxYz0123456789",
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.9f7Qn0",
    "RENDER_GIT_COMMIT=b925422",
    "refs/heads/main",
    "main",
    "v0.1.0",
    "unknown",
    "$RENDER_GIT_COMMIT",
    "",
    "   ",
]


def _named_check(name: str):
    """One result out of the preflight's health section, by check name."""

    return next(
        (result for result in check_health_contract() if result.name == name),
        None,
    )


def _handler_source(route: str) -> str:
    """Source of the handler decorated with `route`, straight from main.py."""

    module = ast.parse(Path(backend_main.__file__).read_text(encoding="utf-8"))
    handler = next(
        node
        for node in ast.walk(module)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and any(
            isinstance(decorator, ast.Call)
            and decorator.args
            and isinstance(decorator.args[0], ast.Constant)
            and decorator.args[0].value == route
            for decorator in node.decorator_list
        )
    )
    return ast.unparse(handler)


# --------------------------------------------------------------------------- #
# What the route answers
# --------------------------------------------------------------------------- #


def test_the_route_reports_the_commit_the_platform_injected(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The whole point, over real HTTP rather than by calling the handler."""

    monkeypatch.setattr(
        backend_main, "settings", replace(backend_main.settings, revision=A_COMMIT_SHA)
    )
    response = client.get(VERSION_ROUTE)
    assert response.status_code == 200
    assert response.json() == {"revision": A_COMMIT_SHA}


def test_the_route_reports_null_when_the_platform_injected_nothing(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Locally, and on any host that is not Render, the variable is absent.

    ``null`` rather than a 500 or an invented string: an unknown revision is a
    normal state, and the route still has to answer.
    """

    monkeypatch.setattr(
        backend_main, "settings", replace(backend_main.settings, revision=None)
    )
    response = client.get(VERSION_ROUTE)
    assert response.status_code == 200
    assert response.json() == {"revision": None}


def test_the_payload_carries_the_revision_and_no_other_field(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A route answering "what is deployed?" invites more fields.

    ``environment``, provider names and feature flags are all configuration,
    and this route is unauthenticated. Pinning the key set is what stops the
    next useful-sounding addition from being published to anyone who asks.
    """

    monkeypatch.setattr(
        backend_main, "settings", replace(backend_main.settings, revision=A_COMMIT_SHA)
    )
    assert set(client.get(VERSION_ROUTE).json()) == {"revision"}


def test_the_route_answers_without_touching_the_database() -> None:
    """It reports the build, so it must answer when the database is down.

    ``Depends(get_db)`` in the signature is what would put a query in front of
    the one route that says which build is running -- during exactly the
    incident that prompts the question.
    """

    route = next(
        route
        for route in backend_main.app.routes
        if getattr(route, "path", "") == VERSION_ROUTE
    )
    injected = [dependency.name for dependency in route.dependant.dependencies]
    assert injected == [], f"{VERSION_ROUTE} now injects {injected}"


# --------------------------------------------------------------------------- #
# What may be published
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize("value", NOT_A_COMMIT_SHA)
def test_a_value_that_is_not_a_commit_sha_never_reaches_the_settings(
    monkeypatch: pytest.MonkeyPatch, value: str
) -> None:
    """The leak guard, driven from the environment through ``load_settings``.

    Asserting on the parser alone would not prove the parser is what the
    settings actually use, so this goes through the real loader.
    """

    monkeypatch.setenv(REVISION_ENV_VAR, value)
    assert load_settings().revision is None


def test_a_real_sha_does_reach_the_settings(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Guards the guard: prove the rejections above are a filter, not a wall.

    Without this, a loader that set ``revision=None`` unconditionally would
    satisfy every rejection check in this file.
    """

    monkeypatch.setenv(REVISION_ENV_VAR, A_COMMIT_SHA)
    assert load_settings().revision == A_COMMIT_SHA


def test_the_loader_reads_the_variable_render_actually_sets(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Nothing else would notice this being wrong.

    A loader reading an unset variable yields ``None``, which is also what a
    correct loader yields on every host that is not Render.
    """

    assert REVISION_ENV_VAR == "RENDER_GIT_COMMIT"
    monkeypatch.setenv("RENDER_GIT_COMMIT", A_COMMIT_SHA)
    assert load_settings().revision == A_COMMIT_SHA


def test_the_parser_normalizes_case_and_surrounding_whitespace() -> None:
    """A pasted value arrives with a newline; some tools print SHAs uppercase.

    Both name the same commit, so both stay usable -- but one published form
    means two probes of one deployment cannot disagree.
    """

    assert commit_sha_or_none(f"  {A_COMMIT_SHA.upper()}\n") == A_COMMIT_SHA


@pytest.mark.parametrize(
    "value",
    [
        A_COMMIT_SHA[:6],
        A_COMMIT_SHA + "0",
        A_COMMIT_SHA[:-1] + "g",
        A_COMMIT_SHA[:20] + " " + A_COMMIT_SHA[21:],
    ],
    ids=["too-short", "too-long", "non-hex-character", "embedded-space"],
)
def test_the_parser_rejects_near_misses(value: str) -> None:
    """Anchored, not searched: a SHA inside a longer string is not a SHA.

    ``A_COMMIT_SHA + "0"`` is the case that matters -- an unanchored pattern
    matches the leading 40 characters and publishes a value the platform never
    set, which is worse than publishing nothing.
    """

    assert commit_sha_or_none(value) is None


def test_an_abbreviated_sha_is_accepted() -> None:
    """Render sends 40 characters; a hand-set value on another host may not.

    Seven is git's own abbreviation floor, and length does not weaken the
    property being defended: it is still hexadecimal or nothing.
    """

    assert commit_sha_or_none(A_COMMIT_SHA[:7]) == A_COMMIT_SHA[:7]


# --------------------------------------------------------------------------- #
# The existing health contracts
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize("route", ["/livez", "/health"])
def test_no_health_route_reports_the_revision(route: str) -> None:
    """The reason this is a third route: neither payload was allowed to change.

    ``/livez`` is what the deployment health gate probes and its payload is a
    literal the preflight requires to stay literal; ``/health``'s field set is
    pinned exactly by ``HEALTH_CONTRACT_KEYS``. A revision added to either
    would be a contract change dressed as an improvement, so it is stated here
    as a failure rather than left to review.
    """

    assert "revision" not in _handler_source(route)


def test_the_liveness_payload_is_still_the_same_literal(
    client: TestClient,
) -> None:
    """Probed over HTTP, because the gate probes it over HTTP."""

    assert client.get("/livez").json() == {"status": "alive"}


# --------------------------------------------------------------------------- #
# The release preflight
# --------------------------------------------------------------------------- #


def test_the_preflight_accepts_the_route_as_written() -> None:
    """Both new checks pass against the real repository."""

    for name in (
        "version_route_answers_without_a_dependency",
        "version_payload_is_the_revision_and_nothing_else",
    ):
        result = _named_check(name)
        assert result is not None, f"the preflight no longer runs {name}"
        assert result.passed, f"{name}: {result.detail}"


def test_the_preflight_rejects_a_version_payload_that_grows_a_field(
    tmp_path: Path,
) -> None:
    """Guards the guard: the check has to be able to fail, not just pass.

    ``environment`` is the realistic mistake -- it is not secret-shaped, so the
    marker scan ``/health`` uses would wave it through, and it is exactly the
    sort of field someone adds to a version endpoint for convenience.
    """

    backend = tmp_path / "backend"
    backend.mkdir()
    (backend / "main.py").write_text(
        '@app.get("/version", tags=["system"])\n'
        "def deployed_revision_probe():\n"
        '    return {"revision": settings.revision, '
        '"environment": settings.app_env}\n',
        encoding="utf-8",
    )

    served = health_payload_sources(tmp_path, route=VERSION_ROUTE)
    leaks = [
        f"{field}={expression}"
        for field, expression in served.items()
        if field != "revision" or expression != VERSION_PAYLOAD_EXPRESSION
    ]
    assert leaks == ["environment=settings.app_env"]


def test_the_preflight_reads_a_version_payload_it_is_shown(
    tmp_path: Path,
) -> None:
    """Guards the guard: an empty read must not look like a clean payload.

    The check fails closed on an empty result for this reason; this proves the
    reader returns something when there is something to return, so that a
    renamed handler is caught by the emptiness rule rather than silently
    passing.
    """

    backend = tmp_path / "backend"
    backend.mkdir()
    (backend / "main.py").write_text(
        '@app.get("/version", tags=["system"])\n'
        "def anything_at_all():\n"
        '    return {"revision": settings.revision}\n',
        encoding="utf-8",
    )

    assert health_payload_sources(tmp_path, route=VERSION_ROUTE) == {
        "revision": VERSION_PAYLOAD_EXPRESSION
    }


# --------------------------------------------------------------------------- #
# Configuration and documentation
# --------------------------------------------------------------------------- #


def test_the_variable_is_platform_supplied_not_deployment_configuration() -> None:
    """It must not be in ``.env.example``, and not merely because it is noise.

    Render sets this per deploy. A value written into our own configuration
    would pin ``/version`` to whatever commit was current when someone typed
    it, and the route would then report the wrong revision with full
    confidence -- worse than reporting none.
    """

    assert REVISION_ENV_VAR in PLATFORM_ENV_KEYS
    assert REVISION_ENV_VAR not in parse_env_file(PROJECT_ROOT / ".env.example")


def test_a_variable_read_through_a_constant_is_still_discovered(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The classification above is only worth something if the scan sees it.

    ``every_runtime_variable_is_documented`` matched string literals only, so
    ``os.getenv(REVISION_ENV_VAR)`` -- one indirection -- was invisible to it.
    That is a hole in the check rather than a quirk of this variable: any
    undocumented read could hide behind a named constant. Dropping
    ``RENDER_GIT_COMMIT`` from :data:`PLATFORM_ENV_KEYS` must therefore make
    the scan report it, which is what this asserts.
    """

    backend = tmp_path / "backend"
    backend.mkdir()
    (backend / "config.py").write_text(
        'SOME_ENV_VAR = "PLATFORM_SUPPLIED_THING"\n'
        "value = os.getenv(SOME_ENV_VAR)\n",
        encoding="utf-8",
    )
    (backend / "main.py").write_text("", encoding="utf-8")

    monkeypatch.setattr(
        "backend.release_preflight.PLATFORM_ENV_KEYS", frozenset()
    )
    from backend.release_preflight import environment_keys_read_by_runtime

    assert "PLATFORM_SUPPLIED_THING" in environment_keys_read_by_runtime(tmp_path)


def test_the_deployment_doc_explains_how_to_read_the_route() -> None:
    """Three answers, each meaning something different; 404 is the subtle one.

    Without the doc a 404 reads as "broken" rather than "the deployed build
    predates this route", which is the most useful thing the route can tell an
    operator chasing a deploy that did not land.
    """

    doc = DEPLOYMENT_DOC.read_text(encoding="utf-8")
    assert VERSION_ROUTE in doc
    assert REVISION_ENV_VAR in doc
    assert "404" in doc
