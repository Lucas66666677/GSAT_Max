#!/usr/bin/env sh
set -eu

PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PYTHON_BIN="${PROJECT_ROOT}/.venv/bin/python"

if [ ! -x "$PYTHON_BIN" ]; then
  python3 -m venv "${PROJECT_ROOT}/.venv"
fi

"$PYTHON_BIN" -m pip install --upgrade pip
"$PYTHON_BIN" -m pip install -r "${PROJECT_ROOT}/requirements.txt"
cd "$PROJECT_ROOT"
exec "$PYTHON_BIN" -m uvicorn backend.main:app --host 0.0.0.0 --port "${PORT:-8000}" --reload
