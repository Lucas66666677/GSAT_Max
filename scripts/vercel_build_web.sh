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
# script only supplies a fallback so a build never silently succeeds with an
# empty backend URL.
set -euo pipefail

FLUTTER_VERSION="3.44.7"
FLUTTER_DIR="${FLUTTER_ROOT:-$HOME/.cache/flutter-$FLUTTER_VERSION}"
API_BASE_URL="${API_BASE_URL:-https://gsat-max-api-lucas.onrender.com}"
APP_ENV="${APP_ENV:-production}"

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
