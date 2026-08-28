"""The response-header contract has to be declared where the public host reads it.

``web/_headers`` declares the website's response headers: four security headers
on every path, an immutable year-long cache for the content-addressed bundle
directories, and ``no-cache`` for ``index.html`` and
``flutter_service_worker.js`` -- the rule ``docs/WEB_DEPLOYMENT.md`` states as
"must not cache ``index.html`` or ``flutter_service_worker.js`` permanently",
because a Flutter web release replaces both in place and a visitor holding a
stale pair keeps running the old bundle against the new API.

That file is the Netlify and Cloudflare Pages format. The public site is
deployed on Vercel -- ``vercel.json`` supplies the build command and
``scripts/vercel_build_web.sh`` runs it -- and Vercel never reads ``_headers``;
it reads a top-level ``headers`` array in ``vercel.json``. ``flutter build web``
copies everything in ``web/`` into ``build/web``, which is the configured
``outputDirectory``, so the file is published as an inert text file at
``/_headers`` while not one of its rules is applied to a response.

Nothing else in the pipeline notices. The self-hosted path implements the same
contract correctly in ``deploy/web/nginx.conf``, so the local full stack that
``docs/WEB_DEPLOYMENT.md`` tells a developer to run does send the headers --
which is what makes the drift invisible from a workstation. The release
preflight's frontend group checks where the bundle points, not what the host
sends back with it; ``scripts/check_api_base_url.sh`` checks the API origin; the
CORS policy governs which origins the API admits, which is a different header on
a different response. A rule can be added to ``web/_headers``, reviewed, and
merged without ever reaching a visitor.

These tests read two files in the checkout and assert they agree. No network
request, no environment variable, no secret.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parents[2]
CONTRACT = PROJECT_ROOT / "web" / "_headers"
SITE_CONFIG = PROJECT_ROOT / "vercel.json"

# The path every response matches, spelled in the contract's glob syntax.
EVERY_PATH = "/*"

# Directories whose file names carry a content hash, so a stale copy is never
# served under a name whose contents changed.
CONTENT_ADDRESSED = ("/assets/*", "/canvaskit/*")

# Rewritten by every release, under a name that does not change.
REPLACED_IN_PLACE = ("/index.html", "/flutter_service_worker.js")

Rules = dict[str, dict[str, str]]


def parse_contract(text: str) -> Rules:
    """Parse the ``_headers`` format: a path, then its indented headers."""
    rules: Rules = {}
    path: str | None = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            path = line.strip()
            rules.setdefault(path, {})
            continue
        if path is None or ":" not in line:
            continue
        key, _, value = line.partition(":")
        rules[path][key.strip()] = value.strip()
    return rules


def contract_path(source: str) -> str:
    """Translate a Vercel ``source`` into the contract's glob syntax."""
    return source.replace("/(.*)", "/*")


def parse_site_config(config: dict) -> Rules:
    """Read the ``headers`` array Vercel actually applies."""
    rules: Rules = {}
    for rule in config.get("headers", []):
        entry = rules.setdefault(contract_path(rule["source"]), {})
        for header in rule.get("headers", []):
            entry[header["key"]] = header["value"]
    return rules


def as_site_config(rules: Rules) -> dict:
    """Spell a set of contract rules the way ``vercel.json`` spells them."""
    return {
        "headers": [
            {
                "source": path.replace("/*", "/(.*)"),
                "headers": [{"key": key, "value": value} for key, value in headers.items()],
            }
            for path, headers in rules.items()
        ]
    }


def parity_violations(contract: Rules, site: Rules) -> list[str]:
    """Compare what the contract declares with what the host would apply."""
    problems: list[str] = []
    for path in sorted(set(contract) - set(site)):
        problems.append(f"{path}: declared in the contract, absent from the host config")
    for path in sorted(set(site) - set(contract)):
        problems.append(f"{path}: applied by the host, absent from the contract")
    for path in sorted(set(contract) & set(site)):
        for key in sorted(set(contract[path]) | set(site[path])):
            declared = contract[path].get(key)
            applied = site[path].get(key)
            if declared != applied:
                problems.append(
                    f"{path}: {key} is {declared!r} in the contract "
                    f"and {applied!r} in the host config"
                )
    return problems


def untranslatable_sources(config: dict) -> list[str]:
    """A source this guard cannot read is a source it cannot vouch for."""
    return [
        rule["source"]
        for rule in config.get("headers", [])
        if any(char in contract_path(rule["source"]) for char in "()[]?+|")
    ]


def permits_reuse(value: str) -> bool:
    """Does this ``Cache-Control`` let a browser serve a copy without asking?"""
    directives = [part.strip().lower() for part in value.split(",")]
    if "immutable" in directives:
        return True
    return any(
        directive.startswith("max-age=") and directive != "max-age=0"
        for directive in directives
    )


def cache_violations(site: Rules) -> list[str]:
    """Cache rules that would outlive the release that shipped the file."""
    problems: list[str] = []
    if "Cache-Control" in site.get(EVERY_PATH, {}):
        problems.append(
            f"{EVERY_PATH}: a catch-all Cache-Control leaves every per-path cache "
            "rule dependent on the host's precedence between overlapping rules"
        )
    for path in REPLACED_IN_PLACE:
        value = site.get(path, {}).get("Cache-Control")
        if value is None:
            problems.append(
                f"{path}: is replaced by every release and declares no Cache-Control"
            )
        elif permits_reuse(value):
            problems.append(
                f"{path}: is replaced by every release and Cache-Control {value!r} "
                "lets a browser reuse the copy it already has"
            )
    for path, headers in sorted(site.items()):
        value = headers.get("Cache-Control", "")
        if path in REPLACED_IN_PLACE or path in CONTENT_ADDRESSED:
            continue
        if permits_reuse(value):
            problems.append(
                f"{path}: Cache-Control {value!r} outlives a release "
                "on a path whose file names carry no content hash"
            )
    return problems


@pytest.fixture(scope="module")
def contract() -> Rules:
    return parse_contract(CONTRACT.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def site_config() -> dict:
    return json.loads(SITE_CONFIG.read_text(encoding="utf-8"))


def test_the_host_that_serves_the_site_applies_the_declared_contract(
    contract: Rules, site_config: dict
) -> None:
    assert untranslatable_sources(site_config) == []
    assert parity_violations(contract, parse_site_config(site_config)) == []


def test_the_cache_rules_in_this_checkout_do_not_outlive_a_release(
    site_config: dict,
) -> None:
    assert cache_violations(parse_site_config(site_config)) == []


def test_the_security_headers_reach_every_response(
    contract: Rules, site_config: dict
) -> None:
    applied = parse_site_config(site_config).get(EVERY_PATH, {})
    declared = {key for key in contract[EVERY_PATH] if key != "Cache-Control"}
    assert declared, "the contract declares no site-wide security headers"
    assert declared <= set(applied)


def test_a_host_config_that_declares_no_headers_is_reported(contract: Rules) -> None:
    """The state this guard was written for: the contract shipped, unapplied."""
    problems = parity_violations(contract, parse_site_config({"rewrites": []}))
    assert len(problems) == len(contract)
    assert all("absent from the host config" in problem for problem in problems)


def test_the_two_spellings_of_a_rule_set_round_trip(contract: Rules) -> None:
    """The stub the drift tests below start from is a faithful, passing one."""
    assert parse_site_config(as_site_config(contract)) == contract
    assert parity_violations(contract, parse_site_config(as_site_config(contract))) == []


def test_a_dropped_rule_is_reported(contract: Rules) -> None:
    thinned = {path: headers for path, headers in contract.items() if path != "/index.html"}
    problems = parity_violations(contract, parse_site_config(as_site_config(thinned)))
    assert problems == [
        "/index.html: declared in the contract, absent from the host config"
    ]


def test_a_drifted_value_is_reported(contract: Rules) -> None:
    drifted = {path: dict(headers) for path, headers in contract.items()}
    drifted[EVERY_PATH]["X-Content-Type-Options"] = "sniff-away"
    problems = parity_violations(contract, parse_site_config(as_site_config(drifted)))
    assert problems == [
        "/*: X-Content-Type-Options is 'nosniff' in the contract "
        "and 'sniff-away' in the host config"
    ]


def test_a_rule_the_contract_never_declared_is_reported(contract: Rules) -> None:
    extra = {path: dict(headers) for path, headers in contract.items()}
    extra["/admin"] = {"X-Debug": "on"}
    problems = parity_violations(contract, parse_site_config(as_site_config(extra)))
    assert problems == ["/admin: applied by the host, absent from the contract"]


def test_a_source_this_guard_cannot_translate_is_reported(contract: Rules) -> None:
    exotic = as_site_config(contract)
    exotic["headers"].append(
        {"source": "/(icons|splash)/(.*)", "headers": [{"key": "X-Test", "value": "1"}]}
    )
    assert untranslatable_sources(exotic) == ["/(icons|splash)/(.*)"]
    assert untranslatable_sources(as_site_config(contract)) == []


@pytest.mark.parametrize(
    "value",
    ("public, max-age=31536000, immutable", "public, max-age=600", "max-age=60"),
)
def test_a_reusable_copy_of_a_file_a_release_replaces_is_reported(value: str) -> None:
    problems = cache_violations({path: {"Cache-Control": value} for path in REPLACED_IN_PLACE})
    assert len(problems) == len(REPLACED_IN_PLACE)
    assert all("lets a browser reuse the copy it already has" in p for p in problems)


def test_a_file_a_release_replaces_needs_a_cache_rule_at_all() -> None:
    problems = cache_violations({EVERY_PATH: {"X-Content-Type-Options": "nosniff"}})
    assert len(problems) == len(REPLACED_IN_PLACE)
    assert all("declares no Cache-Control" in problem for problem in problems)


@pytest.mark.parametrize("value", ("no-cache", "no-store", "public, max-age=0"))
def test_a_revalidated_copy_is_accepted(value: str) -> None:
    site = {path: {"Cache-Control": value} for path in REPLACED_IN_PLACE}
    assert cache_violations(site) == []


def test_a_year_long_cache_outside_the_hashed_directories_is_reported() -> None:
    site = {path: {"Cache-Control": "no-cache"} for path in REPLACED_IN_PLACE}
    site["/manifest.json"] = {"Cache-Control": "public, max-age=31536000, immutable"}
    problems = cache_violations(site)
    assert problems == [
        "/manifest.json: Cache-Control 'public, max-age=31536000, immutable' "
        "outlives a release on a path whose file names carry no content hash"
    ]


def test_a_catch_all_cache_rule_is_reported() -> None:
    site = {path: {"Cache-Control": "no-cache"} for path in REPLACED_IN_PLACE}
    site[EVERY_PATH] = {"Cache-Control": "no-cache"}
    assert cache_violations(site) == [
        f"{EVERY_PATH}: a catch-all Cache-Control leaves every per-path cache "
        "rule dependent on the host's precedence between overlapping rules"
    ]


def test_the_contract_parser_reads_paths_comments_and_blank_lines() -> None:
    parsed = parse_contract(
        "# a comment\n"
        "/*\n"
        "  X-Content-Type-Options: nosniff\n"
        "  Permissions-Policy: camera=(self), microphone=()\n"
        "\n"
        "/index.html\n"
        "  Cache-Control: no-cache\n"
    )
    assert parsed == {
        "/*": {
            "X-Content-Type-Options": "nosniff",
            "Permissions-Policy": "camera=(self), microphone=()",
        },
        "/index.html": {"Cache-Control": "no-cache"},
    }
