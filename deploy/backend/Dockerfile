FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends tesseract-ocr tesseract-ocr-eng \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt ./requirements.txt
RUN python -m pip install --upgrade pip \
    && python -m pip install -r requirements.txt

COPY alembic.ini ./alembic.ini
COPY backend ./backend
COPY deploy/backend/entrypoint.sh /usr/local/bin/gsat-max-entrypoint
RUN sed -i 's/\r$//' /usr/local/bin/gsat-max-entrypoint \
    && chmod +x /usr/local/bin/gsat-max-entrypoint

EXPOSE 8000
ENTRYPOINT ["gsat-max-entrypoint"]
