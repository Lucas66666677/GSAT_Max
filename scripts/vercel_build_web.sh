#!/usr/bin/env bash
# Builds the GSAT_Max Flutter web app on Vercel's build image.
#
# Vercel's "Other" framework preset has no Flutter support, so this script
# bootstraps the exact Flutter SDK version the project's CI (.github/workflows/ci.yml)
# uses, then runs the same `flutter build web --release` invocation CI runs,
# except API_BASE_URL points at the real backend instead of a same-origin "/api"
# path (this is a standalone static frontend, not co-hosted with the backend).
#
# API_BASE_URL and APP_ENV are ordinary Vercel project environment variables,
# not hardcoded here — set API_BASE_URL in the Vercel project settings. This
# script supplies a fallback so a build never silently succeeds with an empty
# backend URL, and check_api_base_url.sh then refuses any value the visitor's
# browser could not reach -- including this site's own origin, which the
# vercel.json rewrite would answer with index.html -- so a bad setting fails
# the build instead of shipping a site that only works on the machine that
# built it.
set -euo pipefail

FLUTTER_VERSION="3.44.7"
FLUTTER_DIR="${FLUTTER_ROOT:-$HOME/.cache/flutter-$FLUTTER_VERSION}"
API_BASE_URL="${API_BASE_URL:-https://gsat-max-api-lucas.onrender.com}"
APP_ENV="${APP_ENV:-production}"

# The names this build knows the site itself by, so the guard can refuse an
# API_BASE_URL that points the site at its own origin -- a backend URL that
# would come back as the SPA shell, because of the vercel.json rewrite. Vercel
# supplies the first two; PUBLIC_APP_URL covers a custom domain the project
# environment declares. Any that is unset arrives empty and is skipped.
SITE_HOSTS=(
  "${VERCEL_PROJECT_PRODUCTION_URL:-}"
  "${VERCEL_URL:-}"
  "${PUBLIC_APP_URL:-}"
)

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
bash "$SCRIPT_DIR/check_api_base_url.sh" "$API_BASE_URL" "${SITE_HOSTS[@]}"

if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  echo "Fetching Flutter $FLUTTER_VERSION..."
  git clone --depth 1 --branch "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_DIR"
else
  echo "Using cached Flutter $FLUTTER_VERSION at $FLUTTER_DIR"
fi

export PATH="$FLUTTER_DIR/bin:$PATH"

flutter config --no-analytics --no-cli-animations
flutter --version

flutter pub get

flutter build web --release \
  --dart-define="APP_ENV=$APP_ENV" \
  --dart-define="API_BASE_URL=$API_BASE_URL"

echo "Build complete: build/web (APP_ENV=$APP_ENV, API_BASE_URL=$API_BASE_URL)"
