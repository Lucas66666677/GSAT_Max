#!/usr/bin/env bash
# Refuses an API_BASE_URL that the public web build cannot actually reach.
#
# scripts/vercel_build_web.sh compiles the public site against whatever
# API_BASE_URL the Vercel project environment holds, and --dart-define bakes
# that value into the bundle. A wrong value therefore produces a green build and
# a site whose every request fails in the visitor's browser, with nothing in the
# pipeline having complained.
#
# Nothing downstream catches it either. lib/core/config/app_config.dart exempts
# localhost and 127.0.0.1 from its production HTTPS rule, and AppConfig.apiBaseUrl
# falls back to http://localhost:8000 when the define is blank -- so a production
# bundle pointed at a local backend passes every existing check. The release
# preflight only inspects the fallback literal written into the build script, not
# the value a real Vercel build uses.
#
# scripts/build_web.ps1 already refuses a plaintext production backend. This is
# the same refusal for the public deployment path.
#
# The backend is a separate deployment, so the API origin must also differ from
# the site's own host. Naming the site itself is the '/api' mistake spelled
# absolutely, and it fails the same way: the vercel.json rewrite answers every
# path with the SPA shell, so requests come back 200 with HTML in them. The
# optional site-host arguments are the names the caller knows the site by; each
# one that is supplied is refused as an API origin.
#
# Reads its arguments and no environment variables, so it never sees a secret.
# The one value it does echo is printed only after userinfo and query strings
# are stripped, because build logs are not a place to put either.
#
# usage: check_api_base_url.sh <api-base-url> [site-host...]
set -euo pipefail

url="${1-}"
shift || true
# A value pasted into a dashboard field often carries surrounding whitespace.
url="${url#"${url%%[![:space:]]*}"}"
url="${url%"${url##*[![:space:]]}"}"

# Credentials do not belong in an API base URL, but if someone puts them there
# the rejection message must not carry them into the build log.
redact() {
  redacted="$1"
  case "$redacted" in *://*@*) redacted="${redacted%%://*}://***@${redacted#*@}" ;; esac
  case "$redacted" in *\?*) redacted="${redacted%%\?*}?***" ;; esac
  case "$redacted" in *\#*) redacted="${redacted%%\#*}#***" ;; esac
  printf '%s' "$redacted"
}

fail() {
  echo "check_api_base_url: $1" >&2
  echo "check_api_base_url: received '$(redact "$url")'" >&2
  echo "check_api_base_url: set API_BASE_URL in the Vercel project settings to" >&2
  echo "  the backend's public HTTPS origin, e.g." >&2
  echo "  https://gsat-max-api-lucas.onrender.com" >&2
  exit 1
}

if [ -z "$url" ]; then
  fail "the value is empty; a blank --dart-define makes AppConfig fall back to http://localhost:8000"
fi

case "$url" in
  /*)
    fail "a same-origin path cannot reach a backend here; vercel.json rewrites /(.*) to /index.html, so it would return the SPA shell instead of the API"
    ;;
esac

case "$url" in
  https://*) ;;
  *) fail "the public site is served over HTTPS, so the API origin must start with https://" ;;
esac

# Split the origin from anything trailing it: AppConfig joins the base directly
# onto '/health' and friends, so the base has to be a bare origin.
rest="${url#https://}"
hostport="${rest%%[/?#]*}"
trailer="${rest#"$hostport"}"

if [ -n "$trailer" ]; then
  fail "the base URL must be a bare origin with no path, query or fragment (drop the '$(redact "$trailer")')"
fi

case "$hostport" in
  \[*\]*) host="${hostport#\[}"; host="${host%%\]*}" ;;
  *) host="${hostport%%:*}" ;;
esac
host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"

if [ -z "$host" ]; then
  fail "the URL has no host"
fi

case "$host" in
  *[!a-z0-9.:-]* | .* | *. | *..*)
    fail "the host is not a valid host name or IP address"
    ;;
esac

case "$host" in
  localhost | *.localhost | *.local | 0.0.0.0 | 127.* | ::1 | :: | \
  10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | \
  169.254.* | fc??:* | fd??:* | fe80:*)
    fail "'$host' is a local or private address that a visitor's browser cannot reach"
    ;;
esac

# A single-label host resolves only inside a private network -- a compose
# service name such as 'backend', or a machine name on the developer's LAN.
case "$host" in
  *.* | *:*) ;;
  *) fail "'$host' has no domain suffix, so it is not publicly resolvable" ;;
esac

# The site's own host, under any name the caller passed. An API base URL naming
# it is the same failure as the '/api' case rejected above: vercel.json rewrites
# /(.*) to /index.html, so /health would answer 200 with the SPA shell and the
# client would try to parse HTML as JSON. Comparison is by authority -- host
# plus any non-default port -- because the site and the backend may legitimately
# share a host on different ports, and 'x:443' and 'x' name one endpoint.
authority() {
  candidate="$1"
  candidate="${candidate#*://}"
  candidate="${candidate%%[/?#]*}"
  case "$candidate" in *@*) candidate="${candidate#*@}" ;; esac
  candidate="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')"
  case "$candidate" in *:443) candidate="${candidate%:443}" ;; esac
  printf '%s' "$candidate"
}

api_authority="$(authority "$url")"
for site in "$@"; do
  # An unset VERCEL_URL or PUBLIC_APP_URL arrives as an empty argument: the
  # caller does not know the site's host, so there is nothing to compare.
  [ -n "$site" ] || continue
  if [ "$api_authority" = "$(authority "$site")" ]; then
    fail "'$api_authority' is the site's own origin; vercel.json rewrites /(.*) to /index.html, so it would return the SPA shell instead of the API"
  fi
done

echo "check_api_base_url: '$host' is a usable public API origin"
