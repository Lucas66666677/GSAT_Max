"""Secret-free release preflight for the GSAT_Max production deployment.

The preflight answers one question before a release goes out: *would this
deployment actually work?* It covers the four wiring mistakes that have
historically taken a release down without failing CI, because CI runs against
the development defaults rather than the production ones:

1. **Configuration shape** -- the production environment satisfies the real
   :meth:`backend.config.Settings.validate` rules, and every variable the
   running service reads is documented in ``.env.example``.
2. **Migration readiness** -- the Alembic history has a single head, an
   unbroken chain, reversible revisions, and a table set that matches the ORM
   models. A drifting head only surfaces at boot, once the old container is
   already gone.
3. **Backend health contracts** -- ``/health``, the ``/livez`` route the
   deployment health gate probes, and the auth surface are registered, the
   gate probes liveness rather than the dependency-sensitive readiness
   route, ``/health`` stays unauthenticated, the Host allowlist runs
   ahead of CORS, and the health payload -- the fields the handler actually
   returns, not just the ones declared here -- exposes neither a secret-shaped
   field name nor a field whose value is built out of a secret.
4. **Frontend-to-backend URL wiring** -- the backend host the web build is
   compiled against is one the backend's own ``TrustedHostMiddleware`` will
   accept, the ``--dart-define`` names the build scripts pass are the ones the
   Dart code actually reads, and the browser origin is present in
   ``API_CORS_ORIGINS``.

**No secret value is ever read into the report, stored, logged, or emitted.**
Variables listed in :data:`SECRET_ENV_KEYS` are reduced at the input boundary
to a presence flag and a character count (:class:`SecretShape`), and
``DATABASE_URL`` is reduced to a credential-free :class:`DatabaseUrlShape`.
When the real settings validator is exercised, it is handed length-preserving
placeholders rather than the values themselves, so the shape checks stay exact
while the secrets stay behind.

The preflight also performs no I/O against the deployment: it opens no database
connection, makes no network request, and changes nothing. It reads repository
files plus a description of the environment, and prints a report.

Usage::

    python -m backend.release_preflight --env-file .env.example
    python -m backend.release_preflight --from-environ \
        --frontend-origin https://gsat-max.example.com --json
"""

from __future__ import annotations

import argparse
import ast
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
from typing import Iterable, Mapping, Sequence
from urllib.parse import urlsplit

PROJECT_ROOT = Path(__file__).resolve().parent.parent

#: Variables whose *values* must never be read into the report. Only presence
#: and length ever cross the input boundary.
SECRET_ENV_KEYS: frozenset[str] = frozenset(
    {
        "JWT_SECRET_KEY",
        "OPENAI_API_KEY",
        "GEMINI_API_KEY",
        "GROQ_API_KEY",
        "REVENUECAT_WEBHOOK_AUTH",
    }
)

#: Variables that carry credentials inside a URL, and so are reduced to a
#: credential-free shape rather than to a presence flag.
CREDENTIALED_URL_ENV_KEYS: frozenset[str] = frozenset({"DATABASE_URL"})

#: Supplied by the operating system or the CI runner rather than by our
#: deployment configuration, so ``.env.example`` is not expected to list them.
PLATFORM_ENV_KEYS: frozenset[str] = frozenset({"CI", "LOCALAPPDATA", "PATH"})

#: The modules that make up the running service. A variable read anywhere in
#: them is deployment configuration and has to be documented.
RUNTIME_CONFIG_MODULES: tuple[str, ...] = ("backend/config.py", "backend/main.py")

#: Keys ``GET /health`` must return, so uptime probes and the release runbook
#: can rely on them.
HEALTH_CONTRACT_KEYS: frozenset[str] = frozenset(
    {
        "status",
        "service",
        "environment",
        "database",
        "openai_configured",
        "configured_ai_providers",
        "ollama_base_url",
    }
)

#: Substrings that must never appear in a ``/health`` field name: the endpoint
#: is unauthenticated, so anything secret-shaped there is public.
SECRET_SHAPED_FIELD_MARKERS: tuple[str, ...] = (
    "api_key",
    "apikey",
    "secret",
    "token",
    "password",
    "credential",
    "database_url",
    "dsn",
)

#: Calls that reduce a value to presence or to a length. A ``/health`` field
#: whose expression mentions a secret is safe only when it is reduced this way:
#: ``bool(OPENAI_API_KEY)`` publishes one bit, ``OPENAI_API_KEY`` publishes the
#: key. This is the same presence-and-length boundary :class:`SecretShape` draws
#: for the environment, applied to the payload the service serves.
SECRET_REDUCING_CALLS: frozenset[str] = frozenset({"bool", "len"})

#: Placeholder recorded by :func:`health_payload_sources` for a field it cannot
#: attribute to a literal key -- a ``**spread`` or a computed key. The contract
#: is no longer readable from the source, so the checks fail rather than guess.
UNREADABLE_HEALTH_FIELD = "<unreadable>"

#: Liveness. Consults nothing, so it reports the process and only the
#: process -- the question a deployment health gate asks.
LIVENESS_ROUTE = "/livez"

#: Readiness. Executes a query, so it reports the database too. A gate
#: pointed here fails on a dependency blip rather than on the process.
READINESS_ROUTE = "/health"

#: Routes the mobile and web clients call by these exact paths, plus the
#: liveness route the deployment health gate probes: dropping it would leave
#: the gate probing a 404 and the service permanently unhealthy.
REQUIRED_ROUTES: tuple[tuple[str, str], ...] = (
    ("GET", LIVENESS_ROUTE),
    ("GET", READINESS_ROUTE),
    ("POST", "/auth/register"),
    ("POST", "/auth/login"),
    ("POST", "/auth/refresh"),
    ("POST", "/auth/logout"),
)

MINIMUM_JWT_SECRET_LENGTH = 32
MINIMUM_UPLOAD_BYTES = 1_048_576

_PROBE_URL = re.compile(r"https?://[^\s'\"]+")
_ENV_LINE = re.compile(r"^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)\s*=(.*)$")
_DART_DEFINE = re.compile(r"--dart-define=\"?([A-Z][A-Z0-9_]*)=")
_DART_FROM_ENVIRONMENT = re.compile(
    r"(?:String|bool|int|double)\.fromEnvironment\(\s*'([A-Z][A-Z0-9_]*)'"
)
_HTTPS_ONLY_DART_GUARD = "Production API_BASE_URL must use HTTPS"


# --------------------------------------------------------------------------- #
# Results
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class CheckResult:
    """One preflight assertion and its outcome."""

    group: str
    name: str
    passed: bool
    detail: str

    def as_dict(self) -> dict[str, object]:
        return {
            "group": self.group,
            "name": self.name,
            "passed": self.passed,
            "detail": self.detail,
        }


@dataclass(frozen=True)
class PreflightReport:
    """Every check that ran, in order."""

    results: tuple[CheckResult, ...]

    @property
    def failures(self) -> tuple[CheckResult, ...]:
        return tuple(result for result in self.results if not result.passed)

    @property
    def passed(self) -> bool:
        return not self.failures

    def result(self, name: str) -> CheckResult:
        """Look one check up by name. Raises if the name is unknown."""
        for candidate in self.results:
            if candidate.name == name:
                return candidate
        raise KeyError(name)

    def as_dict(self) -> dict[str, object]:
        return {
            "passed": self.passed,
            "checks": [result.as_dict() for result in self.results],
        }

    def render(self) -> str:
        lines: list[str] = []
        current_group = ""
        for result in self.results:
            if result.group != current_group:
                current_group = result.group
                lines.append(f"[{current_group}]")
            lines.append(
                f"  {'PASS' if result.passed else 'FAIL'}  "
                f"{result.name}: {result.detail}"
            )
        lines.append("")
        lines.append(
            "PREFLIGHT PASSED"
            if self.passed
            else f"PREFLIGHT FAILED ({len(self.failures)} of {len(self.results)} checks)"
        )
        return "\n".join(lines)


class _Checks:
    """Accumulator so each assertion below reads as a single statement."""

    def __init__(self, group: str) -> None:
        self._group = group
        self.results: list[CheckResult] = []

    def add(self, name: str, passed: object, detail: str) -> None:
        self.results.append(CheckResult(self._group, name, bool(passed), detail))


# --------------------------------------------------------------------------- #
# Secret-free environment description
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class SecretShape:
    """Everything the preflight is permitted to know about a secret."""

    name: str
    present: bool
    length: int

    def placeholder(self) -> str:
        """A value of identical length, for exercising the real validator."""
        return "x" * self.length


@dataclass(frozen=True)
class DatabaseUrlShape:
    """``DATABASE_URL`` with the credentials discarded rather than masked."""

    present: bool
    scheme: str = ""
    host: str = ""
    database: str = ""
    had_credentials: bool = False

    @classmethod
    def parse(cls, raw: str | None) -> "DatabaseUrlShape":
        if not raw or not raw.strip():
            return cls(present=False)
        split = urlsplit(raw.strip())
        if not split.scheme:
            return cls(present=True)
        return cls(
            present=True,
            scheme=split.scheme,
            host=split.hostname or "",
            database=split.path.lstrip("/"),
            had_credentials=bool(split.username or split.password),
        )

    @property
    def is_sqlite(self) -> bool:
        return self.scheme.startswith("sqlite")

    def redacted(self) -> str:
        """A printable form that structurally cannot carry a credential."""
        if not self.present:
            return "(unset)"
        if not self.scheme:
            return "(unparseable)"
        if not self.host and not self.had_credentials:
            # A host-less URL is a local file path such as ``sqlite:///app.db``.
            return f"{self.scheme}:///{self.database}"
        credentials = "***@" if self.had_credentials else ""
        database = f"/{self.database}" if self.database else ""
        return f"{self.scheme}://{credentials}{self.host or '(no host)'}{database}"


@dataclass(frozen=True)
class ProductionEnvironment:
    """A deployment's configuration with every secret already discarded."""

    app_env: str
    cors_origins: tuple[str, ...]
    public_app_url: str
    email_provider: str
    max_upload_bytes: str
    trusted_hosts: tuple[str, ...]
    database_url: DatabaseUrlShape
    secrets: Mapping[str, SecretShape]
    plain: Mapping[str, str] = field(default_factory=dict)

    @classmethod
    def from_mapping(cls, mapping: Mapping[str, str]) -> "ProductionEnvironment":
        """Reduce a raw environment to its shape, at the input boundary.

        Secret values become a :class:`SecretShape` here and nowhere else, so
        no later stage of the preflight is in a position to retain one.
        """

        def value(name: str, default: str = "") -> str:
            return str(mapping.get(name, default)).strip()

        def csv(name: str) -> tuple[str, ...]:
            return tuple(item.strip() for item in value(name).split(",") if item.strip())

        secrets = {
            name: SecretShape(
                name=name,
                present=bool(str(mapping.get(name, "")).strip()),
                length=len(str(mapping.get(name, "")).strip()),
            )
            for name in sorted(SECRET_ENV_KEYS)
        }
        plain = {
            key: str(item)
            for key, item in mapping.items()
            if key not in SECRET_ENV_KEYS and key not in CREDENTIALED_URL_ENV_KEYS
        }
        return cls(
            app_env=value("APP_ENV", "development"),
            cors_origins=csv("API_CORS_ORIGINS"),
            public_app_url=value("PUBLIC_APP_URL"),
            email_provider=value("EMAIL_PROVIDER", "development"),
            max_upload_bytes=value("MAX_UPLOAD_BYTES"),
            trusted_hosts=csv("TRUSTED_HOSTS"),
            database_url=DatabaseUrlShape.parse(mapping.get("DATABASE_URL")),
            secrets=secrets,
            plain=plain,
        )

    @property
    def is_production(self) -> bool:
        return self.app_env.lower() == "production"

    def validator_environment(self) -> dict[str, str]:
        """The environment handed to :func:`backend.config.load_settings`.

        Secrets are replaced by same-length placeholders: the validator only
        measures them, so the check stays exact while the values stay behind.
        ``DATABASE_URL`` is rebuilt from its credential-free shape.
        """
        environment = dict(self.plain)
        for shape in self.secrets.values():
            if shape.present:
                environment[shape.name] = shape.placeholder()
            else:
                environment.pop(shape.name, None)
        if self.database_url.present:
            environment["DATABASE_URL"] = self.database_url.redacted()
        return environment


def parse_env_file(path: Path) -> dict[str, str]:
    """Parse a ``KEY=value`` file. No interpolation, no shell evaluation."""
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = _ENV_LINE.match(line)
        if not match:
            continue
        key, raw = match.group(1), match.group(2).strip()
        if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {"'", '"'}:
            raw = raw[1:-1]
        values[key] = raw
    return values


# --------------------------------------------------------------------------- #
# 1. Production configuration shape
# --------------------------------------------------------------------------- #


def environment_keys_read_by_runtime(project_root: Path = PROJECT_ROOT) -> set[str]:
    """Environment variables the running service reads, discovered via AST.

    Covers ``os.getenv``/``os.environ`` plus ``backend.config``'s own
    ``_csv_environment``/``_bool_environment`` helpers, each of which takes the
    variable name as its first argument.
    """
    readers = {"getenv", "get", "_csv_environment", "_bool_environment"}
    names: set[str] = set()
    for relative in RUNTIME_CONFIG_MODULES:
        tree = ast.parse((project_root / relative).read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and node.args:
                function = node.func
                called = (
                    function.attr
                    if isinstance(function, ast.Attribute)
                    else function.id if isinstance(function, ast.Name) else ""
                )
                first = node.args[0]
                if (
                    called in readers
                    and isinstance(first, ast.Constant)
                    and isinstance(first.value, str)
                    and first.value.isupper()
                ):
                    names.add(first.value)
            elif isinstance(node, ast.Subscript):
                target, key = node.value, node.slice
                if (
                    isinstance(target, ast.Attribute)
                    and target.attr == "environ"
                    and isinstance(key, ast.Constant)
                    and isinstance(key.value, str)
                ):
                    names.add(key.value)
    return names - PLATFORM_ENV_KEYS


def validate_with_real_settings(environment: ProductionEnvironment) -> str | None:
    """Run the service's own validator over placeholder-substituted values.

    Returns a message on rejection and ``None`` on acceptance. Deferring to
    :meth:`backend.config.Settings.validate` keeps the preflight from drifting
    away from the rule the container actually boots against. ``ValueError``
    counts as a rejection too: an unparseable numeric setting crashes the
    container at import time, before the validator is ever reached.
    """
    from backend import config as backend_config

    original = dict(os.environ)
    try:
        os.environ.clear()
        os.environ.update(environment.validator_environment())
        backend_config.load_settings()
    except (RuntimeError, ValueError) as error:
        return str(error)
    finally:
        os.environ.clear()
        os.environ.update(original)
    return None


def check_configuration_shape(
    environment: ProductionEnvironment,
    *,
    project_root: Path = PROJECT_ROOT,
) -> list[CheckResult]:
    checks = _Checks("configuration")

    checks.add(
        "app_env_is_production",
        environment.is_production,
        f"APP_ENV={environment.app_env!r}",
    )

    message = validate_with_real_settings(environment)
    checks.add(
        "settings_validator_accepts_environment",
        message is None,
        "backend.config.Settings.validate accepted the configuration"
        if message is None
        else f"rejected: {message}",
    )

    jwt = environment.secrets["JWT_SECRET_KEY"]
    checks.add(
        "jwt_secret_is_long_enough",
        jwt.present and jwt.length >= MINIMUM_JWT_SECRET_LENGTH,
        f"JWT_SECRET_KEY is {jwt.length} characters "
        f"(minimum {MINIMUM_JWT_SECRET_LENGTH})",
    )

    webhook = environment.secrets["REVENUECAT_WEBHOOK_AUTH"]
    checks.add(
        "revenuecat_webhook_secret_present",
        webhook.present,
        "REVENUECAT_WEBHOOK_AUTH is set"
        if webhook.present
        else "REVENUECAT_WEBHOOK_AUTH is unset; entitlement webhooks would be "
        "unauthenticated",
    )

    provider_keys = [
        name
        for name in ("GEMINI_API_KEY", "GROQ_API_KEY", "OPENAI_API_KEY")
        if environment.secrets[name].present
    ]
    checks.add(
        "at_least_one_ai_provider_key_present",
        provider_keys,
        f"configured providers: {', '.join(provider_keys) or 'none'}",
    )

    rejected_origins = [
        origin
        for origin in environment.cors_origins
        if not origin.startswith("https://")
        or origin.endswith("/")
        or urlsplit(origin).hostname in {"localhost", "127.0.0.1"}
    ]
    checks.add(
        "cors_origins_are_explicit_https",
        environment.cors_origins and not rejected_origins,
        f"API_CORS_ORIGINS={list(environment.cors_origins)}"
        + (f"; rejected {rejected_origins}" if rejected_origins else ""),
    )

    checks.add(
        "public_app_url_is_https",
        environment.public_app_url.startswith("https://")
        and not environment.public_app_url.endswith("/"),
        f"PUBLIC_APP_URL={environment.public_app_url!r}",
    )

    checks.add(
        "email_provider_is_not_development",
        environment.email_provider.lower() not in {"", "development", "test"},
        f"EMAIL_PROVIDER={environment.email_provider!r}",
    )

    upload_bytes = (
        int(environment.max_upload_bytes) if environment.max_upload_bytes.isdigit() else 0
    )
    checks.add(
        "max_upload_bytes_is_sane",
        upload_bytes >= MINIMUM_UPLOAD_BYTES,
        f"MAX_UPLOAD_BYTES={environment.max_upload_bytes!r} "
        f"(minimum {MINIMUM_UPLOAD_BYTES})",
    )

    database = environment.database_url
    checks.add(
        "database_url_is_durable_postgres",
        database.present and not database.is_sqlite and database.host,
        f"DATABASE_URL={database.redacted()}"
        + (
            "; SQLite cannot survive a container replacement or a second replica"
            if database.is_sqlite
            else ""
        ),
    )

    documented = set(parse_env_file(project_root / ".env.example"))
    undocumented = sorted(environment_keys_read_by_runtime(project_root) - documented)
    checks.add(
        "every_runtime_variable_is_documented",
        not undocumented,
        "every variable the service reads appears in .env.example"
        if not undocumented
        else f"read by the service but missing from .env.example: {undocumented}",
    )

    return checks.results


# --------------------------------------------------------------------------- #
# 2. Database migration readiness
# --------------------------------------------------------------------------- #


def migration_scripts(project_root: Path = PROJECT_ROOT) -> list[Path]:
    versions = project_root / "backend" / "migrations" / "versions"
    return sorted(path for path in versions.glob("*.py") if not path.name.startswith("_"))


def _has_executable_body(function: ast.FunctionDef) -> bool:
    """True when the function body is more than a docstring and ``pass``."""
    return any(
        not isinstance(statement, ast.Pass)
        and not (
            isinstance(statement, ast.Expr)
            and isinstance(statement.value, ast.Constant)
            and isinstance(statement.value.value, str)
        )
        for statement in function.body
    )


def tables_created_by_migrations(scripts: Iterable[Path]) -> set[str]:
    tables: set[str] = set()
    for script in scripts:
        tree = ast.parse(script.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if (
                isinstance(node, ast.Call)
                and isinstance(node.func, ast.Attribute)
                and node.func.attr == "create_table"
                and node.args
                and isinstance(node.args[0], ast.Constant)
                and isinstance(node.args[0].value, str)
            ):
                tables.add(node.args[0].value)
    return tables


def check_migration_readiness(
    *, project_root: Path = PROJECT_ROOT
) -> list[CheckResult]:
    from alembic.config import Config as AlembicConfig
    from alembic.script import ScriptDirectory

    from backend.models import Base

    checks = _Checks("migrations")
    scripts = migration_scripts(project_root)
    script_directory = ScriptDirectory.from_config(
        AlembicConfig(str(project_root / "alembic.ini"))
    )

    heads = script_directory.get_heads()
    checks.add(
        "single_migration_head",
        len(heads) == 1,
        f"heads={list(heads)}"
        + ("" if len(heads) == 1 else "; a branch merge left divergent heads"),
    )

    reachable = {revision.revision for revision in script_directory.walk_revisions()}
    orphaned = sorted(
        {script.stem.split("_", 1)[0] for script in scripts} - reachable
    )
    checks.add(
        "revision_chain_is_unbroken",
        not orphaned,
        f"{len(reachable)} revisions reachable from head"
        if not orphaned
        else f"revision files unreachable from head: {orphaned}",
    )

    irreversible = []
    for script in scripts:
        downgrade = next(
            (
                node
                for node in ast.parse(script.read_text(encoding="utf-8")).body
                if isinstance(node, ast.FunctionDef) and node.name == "downgrade"
            ),
            None,
        )
        if downgrade is None or not _has_executable_body(downgrade):
            irreversible.append(script.name)
    checks.add(
        "every_revision_is_reversible",
        not irreversible,
        "every revision implements downgrade()"
        if not irreversible
        else f"no rollback path in: {irreversible}",
    )

    model_tables = set(Base.metadata.tables)
    migrated_tables = tables_created_by_migrations(scripts)
    unmigrated = sorted(model_tables - migrated_tables)
    checks.add(
        "models_are_covered_by_migrations",
        not unmigrated,
        f"all {len(model_tables)} model tables are created by a revision"
        if not unmigrated
        else f"models with no create_table in any revision: {unmigrated}",
    )
    unmodelled = sorted(migrated_tables - model_tables)
    checks.add(
        "migrations_create_no_unmodelled_tables",
        not unmodelled,
        "no leftover tables"
        if not unmodelled
        else f"created by a revision but absent from the models: {unmodelled}",
    )

    env_source = (project_root / "backend" / "migrations" / "env.py").read_text(
        encoding="utf-8"
    )
    overrides_url = (
        'config.set_main_option("sqlalchemy.url"' in env_source
        and "settings.database_url" in env_source
    )
    checks.add(
        "alembic_url_comes_from_settings",
        overrides_url,
        "migrations/env.py overrides alembic.ini's sqlalchemy.url from settings"
        if overrides_url
        else "migrations/env.py leaves alembic.ini's development sqlalchemy.url "
        "in place, so production would migrate the wrong database",
    )

    return checks.results


# --------------------------------------------------------------------------- #
# 3. Backend health contracts
# --------------------------------------------------------------------------- #


def health_payload_sources(
    project_root: Path = PROJECT_ROOT, *, route: str = READINESS_ROUTE
) -> dict[str, str]:
    """Map each field `route` serves to the source of the expression behind it.

    Read statically out of ``backend/main.py``: ``/health`` executes a query, and
    the preflight opens no database connection. The parser follows the route
    decorator rather than a function name so renaming the handler cannot silently
    empty the result.

    Expressions are returned as source text, not values, so nothing a field would
    resolve to at runtime is read here.
    """
    module = ast.parse((project_root / "backend" / "main.py").read_text(encoding="utf-8"))
    handler = next(
        (
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
        ),
        None,
    )
    if handler is None:
        return {}

    returned = next(
        (
            node.value
            for node in ast.walk(handler)
            if isinstance(node, ast.Return) and isinstance(node.value, ast.Dict)
        ),
        None,
    )
    if returned is None:
        return {}

    sources: dict[str, str] = {}
    for key, value in zip(returned.keys, returned.values):
        if isinstance(key, ast.Constant) and isinstance(key.value, str):
            sources[key.value] = ast.unparse(value)
        else:
            sources[UNREADABLE_HEALTH_FIELD] = ast.unparse(value)
    return sources


def _secret_names_in(expression: str) -> list[str]:
    """Secret-shaped identifiers an expression reads, e.g. ``OPENAI_API_KEY``."""
    tree = ast.parse(expression, mode="eval")
    mentioned = {
        name
        for node in ast.walk(tree)
        for name in (
            (node.id,)
            if isinstance(node, ast.Name)
            else (node.attr,)
            if isinstance(node, ast.Attribute)
            else ()
        )
        if any(marker in name.lower() for marker in SECRET_SHAPED_FIELD_MARKERS)
    }
    return sorted(mentioned)


def _is_secret_reducing(expression: str) -> bool:
    """True when the expression publishes a fact about a secret, not the secret.

    ``bool(x)`` and ``len(x)``, a comparison such as ``x is not None``, and a
    ``not x`` all collapse to presence or length. Anything else -- an f-string, a
    slice, a bare read -- carries the value itself into the response.
    """
    node = ast.parse(expression, mode="eval").body
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        return node.func.id in SECRET_REDUCING_CALLS
    if isinstance(node, ast.UnaryOp):
        return isinstance(node.op, ast.Not)
    return isinstance(node, ast.Compare)


def _is_constant(expression: str) -> bool:
    """True when the expression is a literal, so producing it reads nothing."""
    return isinstance(ast.parse(expression, mode="eval").body, ast.Constant)


def deployment_health_gate_probe(project_root: Path = PROJECT_ROOT) -> str | None:
    """The URL path the backend container health gate in ``compose.yaml`` probes.

    ``None`` when no probe can be read at all -- a missing file, a service
    with no healthcheck, a command with no URL in it. The caller fails closed
    on ``None`` rather than reading an unreadable gate as a correct one.
    """
    # PyYAML ships with `uvicorn[standard]`, so parsing the compose file
    # properly costs the preflight no dependency of its own.
    import yaml

    compose = project_root / "compose.yaml"
    if not compose.is_file():
        return None
    document = yaml.safe_load(compose.read_text(encoding="utf-8")) or {}
    service = (document.get("services") or {}).get("backend") or {}
    probe = (service.get("healthcheck") or {}).get("test") or []
    if isinstance(probe, str):
        probe = [probe]
    urls = _PROBE_URL.findall(" ".join(str(part) for part in probe))
    return urlsplit(urls[0]).path or "/" if urls else None


def check_health_contract(*, project_root: Path = PROJECT_ROOT) -> list[CheckResult]:
    from starlette.middleware.cors import CORSMiddleware
    from starlette.middleware.trustedhost import TrustedHostMiddleware

    from backend import main as backend_main

    checks = _Checks("health")
    registered = {
        (method, route.path)
        for route in backend_main.app.routes
        for method in getattr(route, "methods", None) or ()
    }
    missing = [pair for pair in REQUIRED_ROUTES if pair not in registered]
    checks.add(
        "required_routes_are_registered",
        not missing,
        f"all {len(REQUIRED_ROUTES)} client-facing routes are present"
        if not missing
        else f"missing routes: {missing}",
    )

    health = next(
        (route for route in backend_main.app.routes if getattr(route, "path", "") == "/health"),
        None,
    )
    security = getattr(getattr(health, "dependant", None), "security_requirements", ())
    checks.add(
        "health_endpoint_is_unauthenticated",
        health is not None and not security,
        "/health carries no security dependency"
        if health is not None and not security
        else "/health demands credentials, so uptime probes would only ever see 401",
    )

    served = health_payload_sources(project_root)
    # Scan what the handler actually returns as well as what the contract
    # declares: checking the declared set alone only ever proves that a literal
    # in this file is clean, which it is by construction.
    leaky = sorted(
        key
        for key in set(HEALTH_CONTRACT_KEYS) | set(served)
        if any(marker in key.lower() for marker in SECRET_SHAPED_FIELD_MARKERS)
    )
    checks.add(
        "health_contract_exposes_no_secret_field",
        not leaky,
        f"{len(HEALTH_CONTRACT_KEYS)} contract keys, none secret-shaped"
        if not leaky
        else f"secret-shaped keys on an unauthenticated endpoint: {leaky}",
    )

    drift = sorted(set(HEALTH_CONTRACT_KEYS) ^ set(served))
    checks.add(
        "health_contract_matches_the_served_payload",
        served and not drift,
        f"backend/main.py serves exactly the {len(served)} declared fields"
        if served and not drift
        else "/health payload could not be read from backend/main.py"
        if not served
        else f"declared and served fields disagree on: {drift}",
    )

    # A field name can be innocuous while the expression behind it is not:
    # `"service": f"GSAT_Max Backend ({DATABASE_URL})"` keeps the contract's key
    # set intact and publishes the database password to anyone who probes the
    # endpoint. Names are not enough; check what produces each value.
    unreduced = sorted(
        f"{field}={expression}"
        for field, expression in served.items()
        if _secret_names_in(expression) and not _is_secret_reducing(expression)
    )
    checks.add(
        "health_fields_reduce_secrets_to_presence",
        not unreduced,
        "every /health field that reads a secret reduces it to presence"
        if not unreduced
        else "unauthenticated /health fields carry secret values: " + "; ".join(unreduced),
    )

    # A gate is only a liveness gate if the route it probes stays free of
    # dependencies. Read that off the live route rather than the handler body:
    # a `Depends(get_db)` anywhere in the signature is what breaks it.
    live = next(
        (
            route
            for route in backend_main.app.routes
            if getattr(route, "path", "") == LIVENESS_ROUTE
        ),
        None,
    )
    injected = [
        dependency.name
        for dependency in getattr(
            getattr(live, "dependant", None), "dependencies", ()
        )
    ]
    checks.add(
        "liveness_route_consults_no_dependency",
        live is not None and not injected,
        f"{LIVENESS_ROUTE} answers from the process alone"
        if live is not None and not injected
        else f"{LIVENESS_ROUTE} is not registered"
        if live is None
        else f"{LIVENESS_ROUTE} injects {injected}, so the health gate would "
        "report the process as dead whenever a dependency is unreachable",
    )

    # The liveness route is unauthenticated too, and a gate probes it more
    # often than anything else. Requiring literals keeps it from growing a
    # field that reads configuration at all, secret-shaped or not.
    live_served = health_payload_sources(project_root, route=LIVENESS_ROUTE)
    computed = sorted(
        f"{field}={expression}"
        for field, expression in live_served.items()
        if not _is_constant(expression)
    )
    checks.add(
        "liveness_payload_reads_nothing",
        bool(live_served) and not computed,
        f"{LIVENESS_ROUTE} serves {len(live_served)} field(s), all literal"
        if live_served and not computed
        else f"{LIVENESS_ROUTE} payload could not be read from backend/main.py"
        if not live_served
        else f"unauthenticated {LIVENESS_ROUTE} fields are computed: "
        + "; ".join(computed),
    )

    probed = deployment_health_gate_probe(project_root)
    checks.add(
        "deployment_health_gate_probes_liveness",
        probed == LIVENESS_ROUTE,
        f"the backend container health gate probes {LIVENESS_ROUTE}"
        if probed == LIVENESS_ROUTE
        else "no health gate probe could be read from compose.yaml"
        if probed is None
        else f"the health gate probes {probed}, which is dependency-sensitive: "
        "a database blip would mark the backend unhealthy and hold back "
        "everything gated on it",
    )

    stack = [middleware.cls for middleware in backend_main.app.user_middleware]
    ordered = (
        TrustedHostMiddleware in stack
        and CORSMiddleware in stack
        and stack.index(TrustedHostMiddleware) < stack.index(CORSMiddleware)
    )
    checks.add(
        "host_allowlist_runs_before_cors",
        ordered,
        "TrustedHostMiddleware wraps CORSMiddleware"
        if ordered
        else f"middleware order is {[cls.__name__ for cls in stack]}; a spoofed "
        "Host would be answered with CORS headers before it is rejected",
    )

    return checks.results


# --------------------------------------------------------------------------- #
# 4. Frontend-to-backend URL wiring
# --------------------------------------------------------------------------- #


def shell_default(source: str, name: str) -> str:
    """Read ``NAME="${NAME:-default}"`` out of a shell script."""
    match = re.search(rf'^{name}="\$\{{{name}:-([^}}]*)\}}"', source, re.MULTILINE)
    return match.group(1) if match else ""


def check_frontend_wiring(
    environment: ProductionEnvironment | None = None,
    *,
    project_root: Path = PROJECT_ROOT,
    frontend_origin: str | None = None,
) -> list[CheckResult]:
    from backend import main as backend_main

    def read(*parts: str) -> str:
        return project_root.joinpath(*parts).read_text(encoding="utf-8")

    checks = _Checks("frontend")

    api_base_url = shell_default(read("scripts", "vercel_build_web.sh"), "API_BASE_URL")
    parsed = urlsplit(api_base_url)
    checks.add(
        "web_build_api_base_url_is_absolute_https",
        parsed.scheme == "https"
        and parsed.hostname
        and parsed.path in {"", "/"}
        and not api_base_url.endswith("/"),
        f"scripts/vercel_build_web.sh compiles the web app against {api_base_url!r}",
    )

    trusted = {host.strip() for host in backend_main.DEFAULT_TRUSTED_HOSTS.split(",")}
    checks.add(
        "web_build_host_is_trusted_by_the_api",
        parsed.hostname in trusted,
        f"{parsed.hostname!r} is in DEFAULT_TRUSTED_HOSTS"
        if parsed.hostname in trusted
        else f"the web build calls {parsed.hostname!r}, a host "
        "TrustedHostMiddleware would answer with 400",
    )

    same_origin_default = "ARG API_BASE_URL=/api" in read("deploy", "web", "Dockerfile")
    nginx = read("deploy", "web", "nginx.conf")
    proxied = "location /api/" in nginx and "proxy_pass" in nginx
    checks.add(
        "co_hosted_build_has_a_matching_proxy",
        same_origin_default and proxied,
        "deploy/web builds against /api and nginx proxies /api to the backend"
        if same_origin_default and proxied
        else f"Dockerfile default is /api: {same_origin_default}; "
        f"nginx proxies /api: {proxied}",
    )

    build_ps1 = read("scripts", "build_web.ps1")
    guards_https = "StartsWith('https://')" in build_ps1 and "throw" in build_ps1
    checks.add(
        "manual_build_rejects_plaintext_backends",
        guards_https,
        "scripts/build_web.ps1 refuses a non-HTTPS production backend"
        if guards_https
        else "scripts/build_web.ps1 would compile a production build against http://",
    )

    dart_source = read("lib", "core", "config", "app_config.dart")
    read_by_dart = set(_DART_FROM_ENVIRONMENT.findall(dart_source))
    passed_by_builds: set[str] = set()
    for relative in (
        ("scripts", "vercel_build_web.sh"),
        ("scripts", "build_web.ps1"),
        ("deploy", "web", "Dockerfile"),
        (".github", "workflows", "ci.yml"),
    ):
        if project_root.joinpath(*relative).exists():
            passed_by_builds |= set(_DART_DEFINE.findall(read(*relative)))
    ignored = sorted(passed_by_builds - read_by_dart)
    checks.add(
        "dart_defines_match_the_dart_code",
        not ignored,
        f"all {len(passed_by_builds)} --dart-define names are read by AppConfig"
        if not ignored
        else f"build scripts pass defines AppConfig never reads: {ignored}",
    )

    checks.add(
        "dart_config_enforces_https_in_production",
        _HTTPS_ONLY_DART_GUARD in dart_source,
        "AppConfig.resolveApiUri rejects a plaintext production backend"
        if _HTTPS_ONLY_DART_GUARD in dart_source
        else "AppConfig would accept a plaintext production backend",
    )

    if frontend_origin is not None:
        origin = frontend_origin.rstrip("/")
        allowed_origins = (
            {item.rstrip("/") for item in environment.cors_origins} if environment else set()
        )
        checks.add(
            "browser_origin_is_allowed_by_cors",
            origin in allowed_origins,
            f"{origin!r} appears in API_CORS_ORIGINS"
            if origin in allowed_origins
            else f"{origin!r} is absent from API_CORS_ORIGINS, so the browser "
            "would block every request the site makes",
        )
        public_app_url = environment.public_app_url.rstrip("/") if environment else ""
        checks.add(
            "browser_origin_matches_public_app_url",
            public_app_url == origin,
            f"PUBLIC_APP_URL agrees with {origin!r}"
            if public_app_url == origin
            else f"PUBLIC_APP_URL is {public_app_url!r}, so verification and reset "
            f"links would point somewhere other than {origin!r}",
        )

    return checks.results


# --------------------------------------------------------------------------- #
# Entry points
# --------------------------------------------------------------------------- #


def run_preflight(
    environment: ProductionEnvironment,
    *,
    project_root: Path = PROJECT_ROOT,
    frontend_origin: str | None = None,
) -> PreflightReport:
    """Run every check group. Opens no connection and changes nothing."""
    return PreflightReport(
        (
            *check_configuration_shape(environment, project_root=project_root),
            *check_migration_readiness(project_root=project_root),
            *check_health_contract(project_root=project_root),
            *check_frontend_wiring(
                environment,
                project_root=project_root,
                frontend_origin=frontend_origin,
            ),
        )
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m backend.release_preflight",
        description=(
            "Validate a GSAT_Max production release without reading secret "
            "values, connecting to a database, or touching the deployment."
        ),
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--env-file",
        type=Path,
        help="KEY=value file describing the deployment configuration.",
    )
    source.add_argument(
        "--from-environ",
        action="store_true",
        help=(
            "Describe the current process environment instead. Secret values "
            "are reduced to presence and length at the boundary and are never "
            "printed."
        ),
    )
    parser.add_argument(
        "--frontend-origin",
        help="Browser origin the web app is served from, e.g. https://app.example.com.",
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=PROJECT_ROOT,
        help="Repository checkout to inspect (default: the one containing this file).",
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of text.")
    arguments = parser.parse_args(argv)

    mapping = (
        parse_env_file(arguments.env_file)
        if arguments.env_file is not None
        else dict(os.environ)
    )
    report = run_preflight(
        ProductionEnvironment.from_mapping(mapping),
        project_root=arguments.project_root,
        frontend_origin=arguments.frontend_origin,
    )
    print(json.dumps(report.as_dict(), indent=2) if arguments.json else report.render())
    return 0 if report.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
