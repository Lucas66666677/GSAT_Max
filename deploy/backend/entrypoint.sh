#!/bin/sh
set -eu

python -m alembic upgrade head

python backend/seed_data.py \
  --vocab "${SEED_VOCAB:-500}" \
  --grammar "${SEED_GRAMMAR:-50}" \
  --database-url "${DATABASE_URL}" \
  --offline-fallback

exec uvicorn backend.main:app \
  --host 0.0.0.0 \
  --port 8000 \
  --proxy-headers \
  --forwarded-allow-ips="*"
