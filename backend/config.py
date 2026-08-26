from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path

from dotenv import load_dotenv


PROJECT_ROOT = Path(__file__).resolve().parent.parent
BACKEND_ROOT = Path(__file__).resolve().parent
load_dotenv(PROJECT_ROOT / ".env", override=False)


def normalize_database_url(url: str) -> str:
    """Select the installed psycopg 3 driver for provider-style URLs."""
    if url.startswith("postgres://"):
        return url.replace("postgres://", "postgresql+psycopg://", 1)
    if url.startswith("postgresql://"):
        return url.replace("postgresql://", "postgresql+psycopg://", 1)
    return url


def _csv_environment(name: str, default: str = "") -> tuple[str, ...]:
    return tuple(
        item.strip().rstrip("/")
        for item in os.getenv(name, default).split(",")
        if item.strip()
    )


def _bool_environment(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _tesseract_command() -> str | None:
    configured = os.getenv("TESSERACT_CMD")
    if configured:
        return configured

    if os.name == "nt":
        candidates: list[Path] = []
        local_app_data = os.getenv("LOCALAPPDATA")
        if local_app_data:
            candidates.append(
                Path(local_app_data) / "GSAT_Max" / "Tesseract" / "tesseract.exe"
            )
        candidates.extend((
            Path(r"C:\Program Files\Tesseract-OCR\tesseract.exe"),
            Path(r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"),
            PROJECT_ROOT / ".tools" / "tesseract" / "tesseract.exe",
        ))
        for candidate in candidates:
            if candidate.is_file():
                return str(candidate)
    return None


@dataclass(frozen=True)
class Settings:
    app_env: str
    database_url: str
    cors_origins: tuple[str, ...]
    ollama_base_url: str
    ollama_model: str
    ollama_timeout_seconds: float
    openai_base_url: str
    openai_api_key: str | None
    codex_model: str
    openai_timeout_seconds: float
    openai_max_retries: int
    ai_provider_order: tuple[str, ...]
    gemini_base_url: str
    gemini_api_key: str | None
    gemini_model: str
    groq_base_url: str
    groq_api_key: str | None
    groq_model: str
    ai_redact_student_pii: bool
    default_user_email: str
    jwt_secret_key: str
    jwt_expire_minutes: int
    refresh_token_expire_days: int
    revenuecat_webhook_auth: str | None
    max_upload_bytes: int
    email_provider: str
    email_from: str
    public_app_url: str
    tesseract_cmd: str | None

    @property
    def is_production(self) -> bool:
        return self.app_env.lower() == "production"

    def validate(self) -> None:
        if self.is_production and (
            self.jwt_secret_key == "change-this-dev-secret"
            or len(self.jwt_secret_key) < 32
        ):
            raise RuntimeError(
                "Production requires a unique JWT_SECRET_KEY with at least 32 characters."
            )
        if self.is_production and (
            not self.cors_origins
            or "*" in self.cors_origins
            or any(not origin.startswith("https://") for origin in self.cors_origins)
        ):
            raise RuntimeError("Production API_CORS_ORIGINS must contain explicit HTTPS origins.")
        if self.is_production and not self.public_app_url.startswith("https://"):
            raise RuntimeError("Production PUBLIC_APP_URL must use HTTPS.")
        if self.is_production and self.email_provider.lower() in {"development", "test"}:
            raise RuntimeError("Production requires a configured EMAIL_PROVIDER.")
        if self.is_production and not self.revenuecat_webhook_auth:
            raise RuntimeError("Production requires REVENUECAT_WEBHOOK_AUTH.")
        if self.max_upload_bytes < 1_048_576:
            raise RuntimeError("MAX_UPLOAD_BYTES must be at least 1048576 bytes.")


def load_settings() -> Settings:
    default_db = f"sqlite:///{(BACKEND_ROOT / 'gsat_english.db').as_posix()}"
    settings = Settings(
        app_env=os.getenv("APP_ENV", "development"),
        database_url=normalize_database_url(os.getenv("DATABASE_URL", default_db)),
        cors_origins=_csv_environment(
            "API_CORS_ORIGINS",
            "http://localhost:3000,http://localhost:5173,http://localhost:8080,"
            "http://127.0.0.1:3000,http://127.0.0.1:5173,http://127.0.0.1:8080",
        ),
        ollama_base_url=os.getenv("OLLAMA_BASE_URL", "http://localhost:11434").rstrip("/"),
        ollama_model=os.getenv("OLLAMA_MODEL", "llama3.1"),
        ollama_timeout_seconds=float(os.getenv("OLLAMA_TIMEOUT_SECONDS", "90")),
        openai_base_url=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/"),
        openai_api_key=os.getenv("OPENAI_API_KEY") or None,
        codex_model=os.getenv("CODEX_MODEL", os.getenv("OPENAI_MODEL", "gpt-4o-mini")),
        openai_timeout_seconds=float(os.getenv("OPENAI_TIMEOUT_SECONDS", "90")),
        openai_max_retries=max(1, int(os.getenv("OPENAI_MAX_RETRIES", "3"))),
        ai_provider_order=_csv_environment(
            "AI_PROVIDER_ORDER",
            "gemini,groq,openai,ollama",
        ),
        gemini_base_url=os.getenv(
            "GEMINI_BASE_URL",
            "https://generativelanguage.googleapis.com/v1beta/openai",
        ).rstrip("/"),
        gemini_api_key=os.getenv("GEMINI_API_KEY") or None,
        gemini_model=os.getenv("GEMINI_MODEL", "gemini-2.5-flash"),
        groq_base_url=os.getenv(
            "GROQ_BASE_URL",
            "https://api.groq.com/openai/v1",
        ).rstrip("/"),
        groq_api_key=os.getenv("GROQ_API_KEY") or None,
        groq_model=os.getenv("GROQ_MODEL", "openai/gpt-oss-20b"),
        ai_redact_student_pii=_bool_environment("AI_REDACT_STUDENT_PII", True),
        default_user_email=os.getenv("DEFAULT_USER_EMAIL", "demo@student.local"),
        jwt_secret_key=os.getenv("JWT_SECRET_KEY", "change-this-dev-secret"),
        jwt_expire_minutes=int(os.getenv("JWT_EXPIRE_MINUTES", "30")),
        refresh_token_expire_days=int(os.getenv("REFRESH_TOKEN_EXPIRE_DAYS", "30")),
        revenuecat_webhook_auth=os.getenv("REVENUECAT_WEBHOOK_AUTH") or None,
        max_upload_bytes=int(os.getenv("MAX_UPLOAD_BYTES", "10485760")),
        email_provider=os.getenv("EMAIL_PROVIDER", "development"),
        email_from=os.getenv("EMAIL_FROM", "no-reply@gsat-max.local"),
        public_app_url=os.getenv("PUBLIC_APP_URL", "http://localhost:8080").rstrip("/"),
        tesseract_cmd=_tesseract_command(),
    )
    settings.validate()
    return settings


settings = load_settings()
