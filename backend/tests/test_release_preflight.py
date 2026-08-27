"""Tests for the secret-free release preflight.

Two things are being proven here. First, that each check actually fires on the
deployment mistake it exists to catch -- a check that cannot fail is worse than
no check, because it reads as coverage. Second, that the preflight lives up to
its name: no secret value survives the input boundary, so the report is safe to
paste into a pull request or a CI log.
"""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace

import pytest

from backend import main as backend_main
from backend import release_preflight
from backend.release_preflight import (
    LIVENESS_ROUTE,
    READINESS_ROUTE,
    DatabaseUrlShape,
    ProductionEnvironment,
    check_configuration_shape,
    check_frontend_wiring,
    check_health_contract,
    check_migration_readiness,
    parse_env_file,
    run_preflight,
)


PROJECT_ROOT = Path(__file__).resolve().parents[2]

#: Distinctive values, so a leak anywhere in a report is unambiguous.
JWT_SECRET = "sentinel-jwt-" + "z" * 40
DATABASE_PASSWORD = "sentinel-database-password"
PROVIDER_KEY = "sentinel-provider-api-key"
WEBHOOK_SECRET = "sentinel-revenuecat-webhook-secret"
SECRET_VALUES = (JWT_SECRET, DATABASE_PASSWORD, PROVIDER_KEY, WEBHOOK_SECRET)

FRONTEND_ORIGIN = "https://gsat-max.example.com"

PRODUCTION_ENVIRONMENT = {
    "APP_ENV": "production",
    "DATABASE_URL": (
        f"postgresql://gsatmax:{DATABASE_PASSWORD}@db.internal.example:5432/gsatmax"
    ),
    "API_CORS_ORIGINS": FRONTEND_ORIGIN,
    "PUBLIC_APP_URL": FRONTEND_ORIGIN,
    "TRUSTED_HOSTS": "gsat-max-api-lucas.onrender.com",
    "JWT_SECRET_KEY": JWT_SECRET,
    "GEMINI_API_KEY": PROVIDER_KEY,
    "REVENUECAT_WEBHOOK_AUTH": WEBHOOK_SECRET,
    "EMAIL_PROVIDER": "resend",
    "EMAIL_FROM": "no-reply@gsat-max.example.com",
    "MAX_UPLOAD_BYTES": "10485760",
}


def _environment(**overrides: str) -> ProductionEnvironment:
    """A valid production environment with the given fields changed."""
    mapping = {**PRODUCTION_ENVIRONMENT, **overrides}
    for key, value in overrides.items():
        if value == "":
            mapping.pop(key)
    return ProductionEnvironment.from_mapping(mapping)


def _configuration(**overrides: str) -> dict[str, release_preflight.CheckResult]:
    results = check_configuration_shape(
        _environment(**overrides), project_root=PROJECT_ROOT
    )
    return {result.name: result for result in results}


# --------------------------------------------------------------------------- #
# The preflight is secret-free
# --------------------------------------------------------------------------- #


def test_no_secret_value_survives_the_input_boundary() -> None:
    """Secrets are reduced to presence and length, never retained."""
    environment = _environment()

    assert environment.secrets["JWT_SECRET_KEY"].present is True
    assert environment.secrets["JWT_SECRET_KEY"].length == len(JWT_SECRET)
    assert environment.secrets["OPENAI_API_KEY"].present is False

    serialized = repr(environment)
    for secret in SECRET_VALUES:
        assert secret not in serialized


def test_report_never_echoes_a_secret_value() -> None:
    """The rendered and JSON reports are safe to paste into CI output."""
    report = run_preflight(
        _environment(), project_root=PROJECT_ROOT, frontend_origin=FRONTEND_ORIGIN
    )
    rendered = report.render() + json.dumps(report.as_dict())
    for secret in SECRET_VALUES:
        assert secret not in rendered
    # The check still knows the secret is there, without holding it.
    assert report.result("jwt_secret_is_long_enough").passed is True
    assert report.result("database_url_is_durable_postgres").passed is True


def test_database_url_shape_discards_credentials_rather_than_masking_them() -> None:
    shape = DatabaseUrlShape.parse(PRODUCTION_ENVIRONMENT["DATABASE_URL"])
    assert shape.scheme == "postgresql"
    assert shape.host == "db.internal.example"
    assert shape.database == "gsatmax"
    assert shape.had_credentials is True
    assert shape.redacted() == "postgresql://***@db.internal.example/gsatmax"
    assert DATABASE_PASSWORD not in shape.redacted()
    assert "gsatmax:" not in shape.redacted()

    local = DatabaseUrlShape.parse("sqlite:///./backend/gsat_english.db")
    assert local.is_sqlite is True
    assert local.redacted() == "sqlite:///./backend/gsat_english.db"
    assert DatabaseUrlShape.parse(None).redacted() == "(unset)"


def test_validator_environment_substitutes_length_preserving_placeholders() -> None:
    """The real validator is exercised on shapes, not on values."""
    validator_environment = _environment().validator_environment()

    assert len(validator_environment["JWT_SECRET_KEY"]) == len(JWT_SECRET)
    assert validator_environment["JWT_SECRET_KEY"] != JWT_SECRET
    assert "OPENAI_API_KEY" not in validator_environment
    for secret in SECRET_VALUES:
        assert secret not in json.dumps(validator_environment)


def test_settings_validator_check_restores_the_process_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Borrowing os.environ to run the real validator must leave no trace."""
    monkeypatch.setenv("GSAT_MAX_PREFLIGHT_CANARY", "untouched")

    assert release_preflight.validate_with_real_settings(_environment()) is None
    assert release_preflight.validate_with_real_settings(
        _environment(JWT_SECRET_KEY="too-short")
    ) is not None

    import os

    assert os.environ["GSAT_MAX_PREFLIGHT_CANARY"] == "untouched"


# --------------------------------------------------------------------------- #
# 1. Production configuration shape
# --------------------------------------------------------------------------- #


def test_a_correct_production_environment_passes_every_configuration_check() -> None:
    failures = [
        result.name for result in _configuration().values() if not result.passed
    ]
    assert failures == []


@pytest.mark.parametrize(
    ("check_name", "overrides"),
    [
        ("app_env_is_production", {"APP_ENV": "staging"}),
        ("jwt_secret_is_long_enough", {"JWT_SECRET_KEY": "short-secret"}),
        ("revenuecat_webhook_secret_present", {"REVENUECAT_WEBHOOK_AUTH": ""}),
        ("at_least_one_ai_provider_key_present", {"GEMINI_API_KEY": ""}),
        ("cors_origins_are_explicit_https", {"API_CORS_ORIGINS": "*"}),
        (
            "cors_origins_are_explicit_https",
            {"API_CORS_ORIGINS": "http://gsat-max.example.com"},
        ),
        (
            "cors_origins_are_explicit_https",
            {"API_CORS_ORIGINS": "https://localhost:8080"},
        ),
        ("public_app_url_is_https", {"PUBLIC_APP_URL": "http://gsat-max.example.com"}),
        ("email_provider_is_not_development", {"EMAIL_PROVIDER": "development"}),
        ("max_upload_bytes_is_sane", {"MAX_UPLOAD_BYTES": "1024"}),
        ("max_upload_bytes_is_sane", {"MAX_UPLOAD_BYTES": "ten megabytes"}),
        (
            "database_url_is_durable_postgres",
            {"DATABASE_URL": "sqlite:///./backend/gsat_english.db"},
        ),
    ],
)
def test_each_configuration_mistake_is_caught(
    check_name: str, overrides: dict[str, str]
) -> None:
    assert _configuration(**overrides)[check_name].passed is False


def test_settings_validator_check_mirrors_the_running_service() -> None:
    """The preflight defers to the rule the container actually boots against."""
    rejected = _configuration(PUBLIC_APP_URL="http://gsat-max.example.com")[
        "settings_validator_accepts_environment"
    ]
    assert rejected.passed is False
    assert "PUBLIC_APP_URL" in rejected.detail

    # An unparseable numeric setting crashes at import, before validate() runs.
    crashed = _configuration(JWT_EXPIRE_MINUTES="thirty")[
        "settings_validator_accepts_environment"
    ]
    assert crashed.passed is False


def test_env_example_documents_every_variable_the_service_reads() -> None:
    """.env.example is the only inventory operators have; drift strands them."""
    documented = set(parse_env_file(PROJECT_ROOT / ".env.example"))
    read = release_preflight.environment_keys_read_by_runtime(PROJECT_ROOT)

    assert read - documented == set()
    # A spot check that the scanner sees past `os.getenv` into config's helpers.
    assert {"TRUSTED_HOSTS", "API_CORS_ORIGINS", "AI_REDACT_STUDENT_PII"} <= read
    assert _configuration()["every_runtime_variable_is_documented"].passed is True


def test_undocumented_variable_is_reported_against_a_stub_checkout(
    tmp_path: Path,
) -> None:
    """The drift check reads the checkout, so point it at one that has drifted."""
    (tmp_path / "backend").mkdir()
    (tmp_path / ".env.example").write_text("APP_ENV=development\n", encoding="utf-8")
    (tmp_path / "backend" / "config.py").write_text(
        "import os\nAPP_ENV = os.getenv('APP_ENV', 'development')\n", encoding="utf-8"
    )
    (tmp_path / "backend" / "main.py").write_text(
        "import os\nBILLING = os.environ['BILLING_WEBHOOK_URL']\n", encoding="utf-8"
    )

    result = {
        check.name: check
        for check in check_configuration_shape(_environment(), project_root=tmp_path)
    }["every_runtime_variable_is_documented"]
    assert result.passed is False
    assert "BILLING_WEBHOOK_URL" in result.detail


def test_parse_env_file_ignores_comments_and_strips_quotes(tmp_path: Path) -> None:
    path = tmp_path / ".env"
    path.write_text(
        "# a comment\n"
        "\n"
        "APP_ENV=production\n"
        'PUBLIC_APP_URL="https://gsat-max.example.com"\n'
        "export EMAIL_FROM='no-reply@example.com'\n"
        "not a variable line\n",
        encoding="utf-8",
    )
    assert parse_env_file(path) == {
        "APP_ENV": "production",
        "PUBLIC_APP_URL": "https://gsat-max.example.com",
        "EMAIL_FROM": "no-reply@example.com",
    }


# --------------------------------------------------------------------------- #
# 2. Database migration readiness
# --------------------------------------------------------------------------- #


def test_migrations_in_this_checkout_are_release_ready() -> None:
    """Runs the repository's own Alembic history, on a throwaway database."""
    failures = [
        f"{result.name}: {result.detail}"
        for result in check_migration_readiness(project_root=PROJECT_ROOT)
        if not result.passed
    ]
    assert failures == []


def test_model_coverage_check_notices_a_table_with_no_migration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A model added without a revision must fail here, not at boot."""
    real_tables = release_preflight.tables_created_by_migrations

    def missing_one(scripts):
        return real_tables(scripts) - {"weekly_study_packs"}

    monkeypatch.setattr(release_preflight, "tables_created_by_migrations", missing_one)
    results = {
        result.name: result
        for result in check_migration_readiness(project_root=PROJECT_ROOT)
    }
    assert results["models_are_covered_by_migrations"].passed is False
    assert "weekly_study_packs" in results["models_are_covered_by_migrations"].detail


def test_reversibility_check_rejects_an_empty_downgrade(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """`downgrade(): pass` is not a rollback path, however green CI looks."""
    script = tmp_path / "abcdef123456_no_rollback.py"
    script.write_text(
        "def upgrade() -> None:\n"
        "    op.create_table('users')\n"
        "\n"
        "def downgrade() -> None:\n"
        '    """Nothing to undo."""\n'
        "    pass\n",
        encoding="utf-8",
    )
    monkeypatch.setattr(
        release_preflight, "migration_scripts", lambda project_root=None: [script]
    )
    results = {
        result.name: result
        for result in check_migration_readiness(project_root=PROJECT_ROOT)
    }
    assert results["every_revision_is_reversible"].passed is False
    assert "abcdef123456_no_rollback.py" in results["every_revision_is_reversible"].detail
    # The same stub is unreachable from the real head, so the chain check fires.
    assert results["revision_chain_is_unbroken"].passed is False


def _sandbox_checkout(tmp_path: Path) -> Path:
    """A checkout whose Alembic setup is the real one, so only revisions vary."""
    root = tmp_path / "checkout"
    (root / "backend").mkdir(parents=True)
    shutil.copyfile(PROJECT_ROOT / "alembic.ini", root / "alembic.ini")
    shutil.copytree(
        PROJECT_ROOT / "backend" / "migrations",
        root / "backend" / "migrations",
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    return root


def _append_revision(root: Path, revision: str, upgrade: str, downgrade: str) -> None:
    """Add `revision` on top of the sandbox's current head."""
    from alembic.config import Config as AlembicConfig
    from alembic.script import ScriptDirectory

    head = ScriptDirectory.from_config(
        AlembicConfig(str(root / "alembic.ini"))
    ).get_current_head()
    script = "\n".join(
        [
            "from alembic import op",
            "import sqlalchemy as sa",
            "",
            f"revision = {revision!r}",
            f"down_revision = {head!r}",
            "branch_labels = None",
            "depends_on = None",
            "",
            "",
            "def upgrade() -> None:",
            f"    {upgrade}",
            "",
            "",
            "def downgrade() -> None:",
            f"    {downgrade}",
            "",
        ]
    )
    versions = root / "backend" / "migrations" / "versions"
    (versions / f"{revision}_sandbox.py").write_text(script, encoding="utf-8")


def test_preflight_runs_the_migrations_it_declares_ready(tmp_path: Path) -> None:
    """A revision that parses but raises must not pass as migration readiness.

    Every static check still passes here -- the chain is intact, the revision
    is reversible, the model tables are all created -- so without running the
    upgrade the release would go out behind a broken migration.
    """
    root = _sandbox_checkout(tmp_path)
    _append_revision(
        root,
        "aaaa11112222",
        upgrade='op.drop_table("table_that_was_never_created")',
        downgrade='op.execute("SELECT 1")',
    )
    results = {
        result.name: result for result in check_migration_readiness(project_root=root)
    }

    assert results["upgrade_path_reaches_head"].passed is False
    assert "table_that_was_never_created" in results["upgrade_path_reaches_head"].detail
    assert results["revision_chain_is_unbroken"].passed is True
    assert results["every_revision_is_reversible"].passed is True
    assert results["models_are_covered_by_migrations"].passed is True


def test_preflight_compares_the_migrated_schema_to_the_models(tmp_path: Path) -> None:
    """A column the models query but no revision creates is caught before boot.

    The table-level check is satisfied -- `users` is created by a revision --
    so only comparing the applied schema to the models finds the drift.
    """
    root = _sandbox_checkout(tmp_path)
    _append_revision(
        root,
        "bbbb33334444",
        upgrade='op.drop_column("users", "display_name")',
        downgrade='op.add_column("users", sa.Column("display_name", sa.String(120)))',
    )
    results = {
        result.name: result for result in check_migration_readiness(project_root=root)
    }

    assert results["migrated_schema_matches_the_models"].passed is False
    assert "display_name" in results["migrated_schema_matches_the_models"].detail
    assert results["models_are_covered_by_migrations"].passed is True
    assert results["upgrade_path_reaches_head"].passed is True


def test_rehearsal_never_touches_the_configured_database() -> None:
    """A rehearsal that migrated a real database would be a worse bug than the
    one it looks for, so the throwaway URL has to win over alembic.ini's own.
    """
    configured = PROJECT_ROOT / "backend" / "gsat_english.db"
    before = configured.stat().st_mtime_ns if configured.exists() else None

    rehearsal = release_preflight.rehearse_migrations(PROJECT_ROOT)

    assert rehearsal.upgrade_error is None
    assert rehearsal.downgrade_error is None
    assert rehearsal.tables_after_downgrade <= {release_preflight.ALEMBIC_VERSION_TABLE}
    after = configured.stat().st_mtime_ns if configured.exists() else None
    assert after == before


# --------------------------------------------------------------------------- #
# 3. Backend health contracts
# --------------------------------------------------------------------------- #


def test_health_contracts_hold_in_this_checkout() -> None:
    failures = [
        f"{result.name}: {result.detail}"
        for result in check_health_contract()
        if not result.passed
    ]
    assert failures == []


def test_live_health_response_matches_the_declared_contract(client) -> None:
    """The contract the preflight asserts statically is the payload served."""
    response = client.get("/health")
    assert response.status_code == 200

    payload = response.json()
    assert set(payload) == release_preflight.HEALTH_CONTRACT_KEYS
    assert payload["status"] == "ok"
    assert payload["database"] == "reachable"


def test_health_response_exposes_no_secret_shaped_field(client) -> None:
    """/health is unauthenticated, so a secret-shaped field there is public."""
    payload = client.get("/health").json()
    for key in payload:
        assert not any(
            marker in key.lower()
            for marker in release_preflight.SECRET_SHAPED_FIELD_MARKERS
        ), f"/health exposes a secret-shaped field: {key}"
    assert payload["openai_configured"] in {True, False}


def test_missing_route_is_reported(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        release_preflight,
        "REQUIRED_ROUTES",
        (("GET", "/health"), ("POST", "/auth/renamed-endpoint")),
    )
    results = {result.name: result for result in check_health_contract()}
    assert results["required_routes_are_registered"].passed is False
    assert "/auth/renamed-endpoint" in results["required_routes_are_registered"].detail


def test_secret_shaped_health_key_is_reported(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        release_preflight,
        "HEALTH_CONTRACT_KEYS",
        frozenset({"status", "openai_api_key"}),
    )
    results = {result.name: result for result in check_health_contract()}
    assert results["health_contract_exposes_no_secret_field"].passed is False


def _stub_backend_checkout(tmp_path: Path, fields: str) -> Path:
    """A checkout whose ``backend/main.py`` serves `fields` from ``/health``."""
    backend = tmp_path / "backend"
    backend.mkdir()
    (backend / "main.py").write_text(
        "@app.get('/health', tags=['system'])\n"
        "def health_check(db=None):\n"
        "    db.execute(text('SELECT 1'))\n"
        "    return {\n" + fields + "    }\n",
        encoding="utf-8",
    )
    return tmp_path


def test_health_payload_sources_describe_the_route_the_service_serves(client) -> None:
    """The statically parsed payload and the live response must not diverge.

    Every value-level check reads the handler out of the source rather than
    calling it, because the preflight opens no database connection and `/health`
    runs a query. This is what keeps that parse honest.
    """
    served = release_preflight.health_payload_sources(PROJECT_ROOT)
    assert set(served) == set(client.get("/health").json())
    assert release_preflight.UNREADABLE_HEALTH_FIELD not in served


def test_a_health_field_built_from_a_secret_is_reported(tmp_path: Path) -> None:
    """The leak a field-name scan cannot see: innocuous key, secret-bearing value.

    `/health` is unauthenticated, so `f"... ({DATABASE_URL})"` publishes the
    database password to anyone who probes it -- while the contract's key set,
    `status`, and `database` all stay exactly as the existing assertions expect.
    """
    root = _stub_backend_checkout(
        tmp_path,
        '        "status": "ok",\n'
        '        "service": f"GSAT_Max Backend ({DATABASE_URL})",\n',
    )
    results = {
        result.name: result for result in check_health_contract(project_root=root)
    }
    reduced = results["health_fields_reduce_secrets_to_presence"]
    assert reduced.passed is False
    assert "service" in reduced.detail
    # Every key here is innocuous, so the name scan stays green. That is the
    # whole reason the value check has to exist alongside it.
    assert results["health_contract_exposes_no_secret_field"].passed is True


def test_presence_reductions_of_a_secret_are_not_flagged(tmp_path: Path) -> None:
    """`bool(secret)` publishes one bit, not the secret. Flagging it is noise."""
    root = _stub_backend_checkout(
        tmp_path,
        '        "openai_configured": bool(OPENAI_API_KEY),\n'
        '        "key_length": len(settings.jwt_secret_key),\n'
        '        "webhook_configured": settings.revenuecat_webhook_auth is not None,\n',
    )
    results = {
        result.name: result for result in check_health_contract(project_root=root)
    }
    assert results["health_fields_reduce_secrets_to_presence"].passed is True


def test_an_undeclared_health_field_is_reported(tmp_path: Path) -> None:
    """A field added to the handler but not to the contract is drift, not a feature."""
    root = _stub_backend_checkout(
        tmp_path,
        '        "status": "ok",\n        "debug_dump": settings.app_env,\n',
    )
    results = {
        result.name: result for result in check_health_contract(project_root=root)
    }
    drift = results["health_contract_matches_the_served_payload"]
    assert drift.passed is False
    assert "debug_dump" in drift.detail


def test_a_payload_assembled_by_spread_is_not_read_as_clean(tmp_path: Path) -> None:
    """When the contract stops being readable, the check fails rather than guesses."""
    root = _stub_backend_checkout(tmp_path, "        **_diagnostics(),\n")
    results = {
        result.name: result for result in check_health_contract(project_root=root)
    }
    assert results["health_contract_matches_the_served_payload"].passed is False
    assert (
        release_preflight.UNREADABLE_HEALTH_FIELD
        in results["health_contract_matches_the_served_payload"].detail
    )


def _stub_liveness_checkout(tmp_path: Path, fields: str) -> Path:
    """A checkout whose ``backend/main.py`` serves `fields` from the gate route."""
    backend = tmp_path / "backend"
    backend.mkdir(exist_ok=True)
    (backend / "main.py").write_text(
        f"@app.get('{LIVENESS_ROUTE}', tags=['system'])\n"
        "def liveness_probe():\n"
        "    return {\n" + fields + "    }\n",
        encoding="utf-8",
    )
    return tmp_path


def _stub_compose(tmp_path: Path, healthcheck: str) -> Path:
    """A checkout whose ``compose.yaml`` gates the backend on `healthcheck`."""
    _stub_liveness_checkout(tmp_path, '        "status": "alive",\n')
    (tmp_path / "compose.yaml").write_text(
        "services:\n  backend:\n" + healthcheck, encoding="utf-8"
    )
    return tmp_path


def _urlopen_probe(path: str) -> str:
    return (
        "    healthcheck:\n"
        "      test:\n"
        "        - CMD\n"
        "        - python\n"
        "        - -c\n"
        "        - \"import urllib.request; urllib.request.urlopen("
        f"'http://127.0.0.1:8000{path}', timeout=4)\"\n"
    )


def _routes_without(path: str) -> list[object]:
    return [
        route
        for route in backend_main.app.routes
        if getattr(route, "path", "") != path
    ]


def test_the_health_gate_probes_the_route_the_service_actually_serves(client) -> None:
    """The gate's path, the declared liveness route, and the live app agree.

    The gate is configuration in a file nothing else reads, so it is the piece
    most able to drift: a rename here leaves the probe on a 404 and the
    container permanently unhealthy, with every other check still green.
    """
    probe = release_preflight.deployment_health_gate_probe(PROJECT_ROOT)
    assert probe == LIVENESS_ROUTE

    response = client.get(LIVENESS_ROUTE)
    assert response.status_code == 200
    assert response.json() == {"status": "alive"}


def test_liveness_answers_from_the_process_and_readiness_does_not() -> None:
    """The distinction the gate depends on: one route injects, the other cannot.

    If `/livez` ever grows a dependency it stops being a liveness probe, and the
    gate starts reporting a database blip as a dead process.
    """
    dependencies = {
        route.path: [dependency.name for dependency in route.dependant.dependencies]
        for route in backend_main.app.routes
        if getattr(route, "path", "") in {LIVENESS_ROUTE, READINESS_ROUTE}
    }
    assert dependencies[LIVENESS_ROUTE] == []
    assert dependencies[READINESS_ROUTE] != []


def test_a_gate_pointed_at_the_readiness_route_is_reported(tmp_path: Path) -> None:
    root = _stub_compose(tmp_path, _urlopen_probe(READINESS_ROUTE))
    results = {
        result.name: result for result in check_health_contract(project_root=root)
    }
    gate = results["deployment_health_gate_probes_liveness"]
    assert gate.passed is False
    assert READINESS_ROUTE in gate.detail


def test_an_unreadable_gate_fails_closed(tmp_path: Path) -> None:
    """No probe to read is not the same as a correct probe."""
    root = _stub_compose(tmp_path, "    restart: unless-stopped\n")
    results = {
        result.name: result for result in check_health_contract(project_root=root)
    }
    assert results["deployment_health_gate_probes_liveness"].passed is False


def test_a_liveness_route_that_injects_a_dependency_is_reported(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    injected = SimpleNamespace(
        path=LIVENESS_ROUTE,
        methods={"GET"},
        dependant=SimpleNamespace(dependencies=[SimpleNamespace(name="db")]),
    )
    monkeypatch.setattr(
        backend_main.app.router,
        "routes",
        _routes_without(LIVENESS_ROUTE) + [injected],
    )
    results = {result.name: result for result in check_health_contract()}
    assert results["liveness_route_consults_no_dependency"].passed is False
    assert "db" in results["liveness_route_consults_no_dependency"].detail


def test_a_computed_liveness_field_is_reported(tmp_path: Path) -> None:
    """The gate route is unauthenticated, so a field it computes is public."""
    root = _stub_liveness_checkout(
        tmp_path,
        '        "status": "alive",\n        "dsn": DATABASE_URL,\n',
    )
    results = {
        result.name: result for result in check_health_contract(project_root=root)
    }
    payload = results["liveness_payload_reads_nothing"]
    assert payload.passed is False
    assert "dsn=DATABASE_URL" in payload.detail


def test_dropping_the_liveness_route_is_reported(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The gate probes it, so the route has to stay declared."""
    assert ("GET", LIVENESS_ROUTE) in release_preflight.REQUIRED_ROUTES

    monkeypatch.setattr(
        backend_main.app.router, "routes", _routes_without(LIVENESS_ROUTE)
    )
    results = {result.name: result for result in check_health_contract()}
    assert results["required_routes_are_registered"].passed is False
    assert LIVENESS_ROUTE in results["required_routes_are_registered"].detail


# --------------------------------------------------------------------------- #
# 4. Frontend-to-backend URL wiring
# --------------------------------------------------------------------------- #


def test_frontend_wiring_in_this_checkout_is_consistent() -> None:
    failures = [
        f"{result.name}: {result.detail}"
        for result in check_frontend_wiring(
            _environment(), project_root=PROJECT_ROOT, frontend_origin=FRONTEND_ORIGIN
        )
        if not result.passed
    ]
    assert failures == []


def test_web_build_host_must_be_in_the_api_host_allowlist() -> None:
    """The frontend calling a host TrustedHostMiddleware rejects means 400s."""
    from backend import main as backend_main

    api_base_url = release_preflight.shell_default(
        (PROJECT_ROOT / "scripts" / "vercel_build_web.sh").read_text(encoding="utf-8"),
        "API_BASE_URL",
    )
    assert api_base_url.startswith("https://")
    host = api_base_url.removeprefix("https://")
    assert host in {
        item.strip() for item in backend_main.DEFAULT_TRUSTED_HOSTS.split(",")
    }


def test_untrusted_web_build_host_is_reported(tmp_path: Path) -> None:
    """The exact regression this check exists for: a renamed backend host."""
    checkout = _stub_frontend_checkout(tmp_path)
    (checkout / "scripts" / "vercel_build_web.sh").write_text(
        'API_BASE_URL="${API_BASE_URL:-https://gsat-max-api-renamed.onrender.com}"\n',
        encoding="utf-8",
    )
    results = {
        result.name: result
        for result in check_frontend_wiring(_environment(), project_root=checkout)
    }
    assert results["web_build_host_is_trusted_by_the_api"].passed is False
    assert "400" in results["web_build_host_is_trusted_by_the_api"].detail


def test_plaintext_web_build_backend_is_reported(tmp_path: Path) -> None:
    checkout = _stub_frontend_checkout(tmp_path)
    (checkout / "scripts" / "vercel_build_web.sh").write_text(
        'API_BASE_URL="${API_BASE_URL:-http://gsat-max-api-lucas.onrender.com}"\n',
        encoding="utf-8",
    )
    results = {
        result.name: result
        for result in check_frontend_wiring(_environment(), project_root=checkout)
    }
    assert results["web_build_api_base_url_is_absolute_https"].passed is False


def test_dart_define_typo_is_reported(tmp_path: Path) -> None:
    """A misspelled define silently compiles in AppConfig's default instead."""
    checkout = _stub_frontend_checkout(tmp_path)
    (checkout / "scripts" / "build_web.ps1").write_text(
        "if ($ApiBaseUrl.StartsWith('https://')) { } else { throw 'no' }\n"
        '"--dart-define=API_BASE_URLS=$ApiBaseUrl"\n',
        encoding="utf-8",
    )
    results = {
        result.name: result
        for result in check_frontend_wiring(_environment(), project_root=checkout)
    }
    assert results["dart_defines_match_the_dart_code"].passed is False
    assert "API_BASE_URLS" in results["dart_defines_match_the_dart_code"].detail


@pytest.mark.parametrize(
    ("check_name", "overrides"),
    [
        ("browser_origin_is_allowed_by_cors", {"API_CORS_ORIGINS": "https://other.example"}),
        ("browser_origin_matches_public_app_url", {"PUBLIC_APP_URL": "https://other.example"}),
    ],
)
def test_browser_origin_mismatches_are_caught(
    check_name: str, overrides: dict[str, str]
) -> None:
    results = {
        result.name: result
        for result in check_frontend_wiring(
            _environment(**overrides),
            project_root=PROJECT_ROOT,
            frontend_origin=FRONTEND_ORIGIN,
        )
    }
    assert results[check_name].passed is False


def test_origin_checks_are_skipped_when_no_origin_is_supplied() -> None:
    names = {
        result.name
        for result in check_frontend_wiring(_environment(), project_root=PROJECT_ROOT)
    }
    assert "browser_origin_is_allowed_by_cors" not in names


def _stub_frontend_checkout(tmp_path: Path) -> Path:
    """A checkout whose frontend wiring files can be edited one at a time."""
    for relative in (
        ("scripts", "vercel_build_web.sh"),
        ("scripts", "build_web.ps1"),
        ("deploy", "web", "Dockerfile"),
        ("deploy", "web", "nginx.conf"),
        ("lib", "core", "config", "app_config.dart"),
        (".github", "workflows", "ci.yml"),
    ):
        destination = tmp_path.joinpath(*relative)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(
            PROJECT_ROOT.joinpath(*relative).read_text(encoding="utf-8"),
            encoding="utf-8",
        )
    return tmp_path


# --------------------------------------------------------------------------- #
# Command line
# --------------------------------------------------------------------------- #


def test_cli_reports_the_development_template_as_not_release_ready() -> None:
    """`.env.example` is a development config, so the preflight must reject it.

    Run out of process: the checks borrow ``os.environ`` to exercise the real
    settings validator, and the CLI is what CI would invoke anyway.
    """
    completed = subprocess.run(
        [
            sys.executable,
            "-m",
            "backend.release_preflight",
            "--env-file",
            str(PROJECT_ROOT / ".env.example"),
            "--json",
        ],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert completed.returncode == 1, completed.stderr

    report = json.loads(completed.stdout)
    assert report["passed"] is False
    failed = {check["name"] for check in report["checks"] if not check["passed"]}
    assert "app_env_is_production" in failed
    assert "database_url_is_durable_postgres" in failed
    # Everything that is not environment-dependent must still be green.
    assert "every_runtime_variable_is_documented" not in failed
    assert not {check["group"] for check in report["checks"] if not check["passed"]} & {
        "migrations",
        "health",
        "frontend",
    }
