import base64
import asyncio
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from datetime import date, datetime, timedelta, timezone
import hashlib
import hmac
import html
from io import BytesIO
import json
import os
from pathlib import Path
import re
import secrets
import time
from threading import Lock
from typing import Any, Generator
from urllib.parse import quote
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import httpx
from alembic import command as alembic_command
from alembic.config import Config as AlembicConfig
from fastapi import BackgroundTasks, Depends, FastAPI, File, Form, Header, HTTPException, Request, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import StreamingResponse
from PIL import Image
from pydantic import BaseModel, Field, ValidationError
import pytesseract
from sqlalchemy import create_engine, func, select, text
from sqlalchemy.orm import Session, sessionmaker

try:
    from .config import settings
    from .email_service import get_email_provider
except ImportError:
    from config import settings
    from email_service import get_email_provider

if settings.tesseract_cmd:
    pytesseract.pytesseract.tesseract_cmd = settings.tesseract_cmd

try:
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_CENTER
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
    from reportlab.lib.units import mm
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.cidfonts import UnicodeCIDFont
    from reportlab.pdfbase.ttfonts import TTFont
    from reportlab.platypus import (
        Paragraph,
        PageBreak,
        KeepTogether,
        SimpleDocTemplate,
        Spacer,
        Table,
        TableStyle,
    )
except ImportError:
    colors = None
    TA_CENTER = 1
    A4 = (595.2755905511812, 841.8897637795277)
    ParagraphStyle = None
    getSampleStyleSheet = None
    mm = 2.834645669291339
    pdfmetrics = None
    UnicodeCIDFont = None
    TTFont = None
    Paragraph = None
    PageBreak = None
    KeepTogether = None
    SimpleDocTemplate = None
    Spacer = None
    Table = None
    TableStyle = None

try:
    from .models import (
        AICache,
        Base,
        DailyExpansionQuiz,
        DailyMissionTask,
        LearningProgressEvent,
        LearningRewardState,
        EmailActionToken,
        BackgroundJob,
        GrammarConceptBank,
        GrammarErrorLedger,
        GSATReferencePaper,
        MockExamAttempt,
        MockExamSet,
        RefreshToken,
        ReviewSyncReceipt,
        User,
        UserLearningPreference,
        UserVocabProgress,
        Vocabulary,
        WeeklyStudyPack,
        WritingEvaluationRecord,
    )
except ImportError:
    from models import (
        AICache,
        Base,
        DailyExpansionQuiz,
        DailyMissionTask,
        LearningProgressEvent,
        LearningRewardState,
        EmailActionToken,
        BackgroundJob,
        GrammarConceptBank,
        GrammarErrorLedger,
        GSATReferencePaper,
        MockExamAttempt,
        MockExamSet,
        RefreshToken,
        ReviewSyncReceipt,
        User,
        UserLearningPreference,
        UserVocabProgress,
        Vocabulary,
        WeeklyStudyPack,
        WritingEvaluationRecord,
    )


DATABASE_URL = settings.database_url
OLLAMA_BASE_URL = settings.ollama_base_url
OLLAMA_MODEL = settings.ollama_model
OLLAMA_TIMEOUT_SECONDS = settings.ollama_timeout_seconds
OPENAI_BASE_URL = settings.openai_base_url
OPENAI_API_KEY = settings.openai_api_key
CODEX_MODEL = settings.codex_model
OPENAI_TIMEOUT_SECONDS = settings.openai_timeout_seconds
OPENAI_MAX_RETRIES = settings.openai_max_retries
AI_PROVIDER_ORDER = settings.ai_provider_order
GEMINI_BASE_URL = settings.gemini_base_url
GEMINI_API_KEY = settings.gemini_api_key
GEMINI_MODEL = settings.gemini_model
GROQ_BASE_URL = settings.groq_base_url
GROQ_API_KEY = settings.groq_api_key
GROQ_MODEL = settings.groq_model
AI_REDACT_STUDENT_PII = settings.ai_redact_student_pii
DEFAULT_USER_EMAIL = settings.default_user_email
JWT_SECRET_KEY = settings.jwt_secret_key
JWT_ALGORITHM = "HS256"
JWT_EXPIRE_MINUTES = settings.jwt_expire_minutes
# OWASP's headline figure for PBKDF2-HMAC-SHA256 is 600k, but its actual advice
# is to tune the cost to roughly one second on the hardware you run on. Measured
# on this deployment's Render free tier (0.1 CPU): 120k already costs ~1s per
# login, and 600k would cost ~5s -- unusable, and a DoS amplifier against a
# single shared tenth of a core. So the default stays 120k *for this hardware*
# and the cost is env-tunable instead: raise PASSWORD_HASH_ITERATIONS as soon as
# the service moves to paid compute. Existing users are upgraded automatically
# on their next successful login (see maybe_upgrade_password_hash), because the
# iteration count is stored per-hash rather than assumed.
def password_hash_iterations_from_env() -> int:
    """Read a safe PBKDF2 cost without making a bad deploy variable fatal."""
    raw_value = os.getenv("PASSWORD_HASH_ITERATIONS", "120000")
    try:
        configured_iterations = int(raw_value)
    except ValueError:
        return 120_000
    return max(120_000, configured_iterations)


PASSWORD_HASH_ITERATIONS = password_hash_iterations_from_env()
_RATE_LIMIT_BUCKETS: dict[str, deque[float]] = defaultdict(deque)
_RATE_LIMIT_LOCK = Lock()

engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {},
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def run_database_migrations() -> None:
    config_path = Path(__file__).resolve().parent.parent / "alembic.ini"
    migration_config = AlembicConfig(str(config_path))
    alembic_command.upgrade(migration_config, "head")


@asynccontextmanager
async def app_lifespan(_: FastAPI):
    run_database_migrations()
    with SessionLocal() as db:
        ensure_user(db, user_id=1)
    yield


app = FastAPI(title="GSAT_Max Backend", lifespan=app_lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=list(settings.cors_origins),
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
)
# The production hostname is part of the *default* allowlist on purpose. This
# service has no custom domain, so `gsat-max-api-lucas.onrender.com` is the only
# host real traffic ever arrives on -- allowing it is exactly what a correctly
# configured `TRUSTED_HOSTS` would do, not a loosening of it. Keeping it in the
# default means shipping this middleware cannot lock the live API out with 400s
# if the env var is missing or misspelled on the host, which is the one failure
# mode that would take the whole backend down rather than harden it.
DEFAULT_TRUSTED_HOSTS = "gsat-max-api-lucas.onrender.com,localhost,127.0.0.1,testserver"
trusted_hosts = [
    item.strip()
    for item in os.getenv("TRUSTED_HOSTS", DEFAULT_TRUSTED_HOSTS).split(",")
    if item.strip()
]
app.add_middleware(TrustedHostMiddleware, allowed_hosts=trusted_hosts)


class PerformanceMetrics(BaseModel):
    total_time_seconds: float = Field(
        description="Total AI inference time in seconds."
    )
    tokens_per_second: float = Field(
        description="Generated or reported tokens divided by inference time."
    )
    total_tokens: int = Field(description="Total tokens reported by the AI provider.")
    cached: bool = Field(default=False, description="Whether this response came from cache.")
    provider: str | None = Field(default=None, description="AI provider that served the request.")
    model: str | None = Field(default=None, description="AI model that served the request.")


class AuthRegisterRequest(BaseModel):
    email: str
    password: str = Field(min_length=8)
    display_name: str | None = None


class AuthLoginRequest(BaseModel):
    email: str
    password: str


class AuthRefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=32)


class AuthLogoutRequest(BaseModel):
    refresh_token: str = Field(min_length=32)


class AuthUserResponse(BaseModel):
    user_id: int
    email: str
    display_name: str | None = None
    current_streak: int = 0
    has_completed_onboarding: bool = False
    is_pro: bool = False
    email_verified: bool = False


class AuthTokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    expires_in: int
    token_type: str = "bearer"
    user_id: int
    email: str
    display_name: str | None = None
    current_streak: int = 0
    has_completed_onboarding: bool = False
    is_pro: bool = False


class EmailActionRequest(BaseModel):
    email: str | None = None


class EmailActionConfirmRequest(BaseModel):
    token: str = Field(min_length=32)


class PasswordResetConfirmRequest(BaseModel):
    token: str = Field(min_length=32)
    new_password: str = Field(min_length=8)


class EmailActionResponse(BaseModel):
    status: str = "accepted"
    debug_token: str | None = None


class UserStatsResponse(BaseModel):
    total_words_mastered: int
    average_grammar_score: float
    total_essays_written: int
    vocabulary_skill: float = 0.0
    grammar_skill: float = 0.0
    reading_skill: float = 0.0
    writing_skill: float = 0.0


class LearningPreferencesResponse(BaseModel):
    weekday_minutes: int
    weekend_minutes: int
    preferred_session_minutes: int
    rescue_session_minutes: int
    maximum_session_minutes: int
    weekly_goal_days: int
    timezone: str
    gentle_streak_enabled: bool
    paper_pack_enabled: bool


class LearningPreferencesUpdateRequest(BaseModel):
    weekday_minutes: int | None = Field(default=None, ge=3, le=60)
    weekend_minutes: int | None = Field(default=None, ge=3, le=90)
    preferred_session_minutes: int | None = Field(default=None, ge=3, le=60)
    rescue_session_minutes: int | None = Field(default=None, ge=2, le=10)
    maximum_session_minutes: int | None = Field(default=None, ge=10, le=90)
    weekly_goal_days: int | None = Field(default=None, ge=1, le=7)
    timezone: str | None = Field(default=None, min_length=3, max_length=80)
    gentle_streak_enabled: bool | None = None
    paper_pack_enabled: bool | None = None


class RewardSummary(BaseModel):
    total_points: int
    level: int
    level_progress: float
    points_to_next_level: int
    weekly_active_days: int
    weekly_goal_days: int
    weekly_goal_progress: float
    comeback_count: int
    streak_shields: int
    current_streak: int
    headline: str


class RewardFeedback(BaseModel):
    awarded: bool
    points: int
    message: str
    total_points: int
    level: int
    level_up: bool = False


class LearningEventRequest(BaseModel):
    source_key: str = Field(min_length=6, max_length=120)
    event_type: str = Field(min_length=3, max_length=80)
    skill: str | None = Field(default=None, max_length=40)
    outcome: str | None = Field(default=None, max_length=40)
    metadata: dict[str, Any] = Field(default_factory=dict)


class LearningEventResponse(BaseModel):
    reward: RewardFeedback
    summary: RewardSummary


class DailyScheduleTask(BaseModel):
    id: int
    task_key: str
    type: str
    status: str = "pending"
    count: int | None = None
    topic: str | None = None
    minutes: int | None = None
    priority: str = "core"
    difficulty: str = "foundation"
    success_target: float = 0.85
    reward_points: int = 10
    reward: RewardFeedback | None = None


class DailyScheduleResponse(BaseModel):
    target_exam_date: datetime
    days_remaining: int
    upward_curve: float
    focus_skill: str
    available_minutes: int
    planned_minutes: int
    session_mode: str
    can_stop_when_complete: bool = True
    encouragement: str
    reward_summary: RewardSummary
    tasks: list[DailyScheduleTask]


class DailyScheduleTaskUpdateRequest(BaseModel):
    completed: bool


class DailyScheduleReplanRequest(BaseModel):
    available_minutes: int = Field(ge=3, le=60)


class TargetExamDateRequest(BaseModel):
    target_exam_date: datetime


class OnboardingAnswer(BaseModel):
    question_id: str
    category: str
    selected_index: int
    correct_index: int
    is_correct: bool


class UserInitializeRequest(BaseModel):
    answers: list[OnboardingAnswer] = Field(min_length=5, max_length=5)


class UserInitializeResponse(BaseModel):
    seeded_words: int
    correct_count: int
    has_completed_onboarding: bool
    stats: UserStatsResponse


class GrammarRequest(BaseModel):
    sentence: str = ""
    user_id: int = 1
    mode: str = "correction"
    app_mode: str = "engagement"


class GrammarResponse(BaseModel):
    correction: str
    performance_metrics: PerformanceMetrics
    concept: str | None = None
    question: str | None = None
    options: list[str] | None = None
    correct_option_index: int | None = None
    explanation: str | None = None


class WritingRequest(BaseModel):
    essay: str
    user_id: int = 1
    essay_type: str = "standard"
    app_mode: str = "engagement"


class WritingScoreBreakdown(BaseModel):
    content: float = Field(ge=0, le=5)
    organization: float = Field(ge=0, le=5)
    grammar: float = Field(ge=0, le=5)
    vocabulary: float = Field(ge=0, le=5)


class WritingCorrection(BaseModel):
    category: str
    start_index: int | None = Field(default=None, ge=0)
    end_index: int | None = Field(default=None, ge=0)
    error_text: str
    original_sentence: str
    corrected_sentence: str
    reason: str


class WritingVocabularyAlternative(BaseModel):
    original: str
    advanced: str
    usage_note: str


class WritingEvaluation(BaseModel):
    total_score: float = Field(ge=0, le=20)
    max_score: float = 20
    scores: WritingScoreBreakdown
    spelling_and_punctuation_issues: list[WritingCorrection] = Field(default_factory=list)
    corrections: list[WritingCorrection] = Field(default_factory=list)
    strengths: list[str] = Field(default_factory=list)
    priority_improvements: list[str] = Field(default_factory=list)
    suggested_template: list[str] = Field(default_factory=list)
    advanced_vocabulary_alternatives: list[WritingVocabularyAlternative] = Field(
        default_factory=list
    )
    demonstration: str
    rubric_version: str = "gsat-writing-v1"


class WritingResponse(BaseModel):
    evaluation_id: int
    evaluation: WritingEvaluation
    feedback: str
    performance_metrics: PerformanceMetrics


class ReadingRequest(BaseModel):
    topic: str = "education"
    level: str = "GSAT Level 4"
    word_count: int = 350
    app_mode: str = "engagement"


class ReadingResponse(BaseModel):
    article: str
    performance_metrics: PerformanceMetrics


class ClozePhrasesRequest(BaseModel):
    topic: str = "school life and exam preparation"
    force_refresh: bool = False
    app_mode: str = "engagement"


class ClozePhrasesResponse(BaseModel):
    text: str
    phrases: list[str]
    correct_mapping: dict[str, str]
    performance_metrics: PerformanceMetrics


class MixedQuestionRequest(BaseModel):
    topic: str = "technology, education, and youth habits"
    difficulty: str = "GSAT"
    force_refresh: bool = False
    app_mode: str = "engagement"


class MixedMultipleChoiceQuestion(BaseModel):
    number: int
    question: str
    options: list[str]
    correct_option_index: int
    explanation: str


class MixedShortAnswerQuestion(BaseModel):
    number: int
    question: str
    reference_answer: str
    max_score: int = 2
    rubric: str


class MixedQuestionsResponse(BaseModel):
    text_a: str
    text_b: str
    multiple_choice: list[MixedMultipleChoiceQuestion]
    short_answer: list[MixedShortAnswerQuestion]
    performance_metrics: PerformanceMetrics


class MixedAnswerEvaluationRequest(BaseModel):
    question: str
    reference_answer: str
    student_answer: str
    max_score: int = 2
    rubric: str | None = None
    app_mode: str = "engagement"


class MixedAnswerEvaluationResponse(BaseModel):
    score: int
    max_score: int
    feedback: str
    performance_metrics: PerformanceMetrics


class TranslationDeduction(BaseModel):
    error_text: str
    error_type: str
    points: float
    explanation: str


class TranslationEvaluationRequest(BaseModel):
    chinese_sentence: str
    student_translation: str
    grammar_concept: str | None = None
    app_mode: str = "engagement"


class TranslationEvaluationResponse(BaseModel):
    final_score: float
    deductions: list[TranslationDeduction]
    suggested_translation: str
    grammar_concept: str
    performance_metrics: PerformanceMetrics


class TranslationSimilarRequest(BaseModel):
    grammar_concept: str
    source_sentence: str | None = None
    app_mode: str = "engagement"


class TranslationSimilarResponse(BaseModel):
    chinese_sentence: str
    grammar_concept: str
    performance_metrics: PerformanceMetrics


class SentenceUpgradeGenerateRequest(BaseModel):
    focus: str | None = None
    force_refresh: bool = False
    app_mode: str = "engagement"


class SentenceUpgradeGenerateResponse(BaseModel):
    basic_sentence: str
    target_structure: str
    instruction: str
    performance_metrics: PerformanceMetrics


class SentenceUpgradeEvaluateRequest(BaseModel):
    basic_sentence: str
    target_structure: str
    student_sentence: str
    app_mode: str = "engagement"


class SentenceUpgradeEvaluateResponse(BaseModel):
    passed: bool
    feedback: str
    suggested_upgrade: str
    detected_structure: str
    performance_metrics: PerformanceMetrics


class FullMockExamRequest(BaseModel):
    difficulty: str = "GSAT"
    version: str = "standard-v1"
    force_refresh: bool = False
    app_mode: str = "engagement"


class FullMockExamResponse(BaseModel):
    exam_id: str
    title: str
    generated_at: datetime
    sections: list[dict[str, Any]]
    non_choice: dict[str, Any]
    performance_metrics: PerformanceMetrics


class FullMockExamEvaluationRequest(BaseModel):
    exam_id: str
    selected_answers: dict[int, int] = Field(default_factory=dict)
    translation_answer: str = ""
    essay_answer: str = ""
    app_mode: str = "focus"


class FullMockExamSubjectiveEvaluation(BaseModel):
    translation_score: float = Field(ge=0, le=10)
    essay_score: float = Field(ge=0, le=20)
    translation_feedback: str
    essay_feedback: str
    priority_improvements: list[str] = Field(default_factory=list)
    rubric_version: str = "gsat-mock-v1"


class FullMockExamEvaluationResponse(BaseModel):
    attempt_id: str
    exam_id: str
    total_score: float = Field(ge=0, le=100)
    objective_score: float = Field(ge=0, le=70)
    objective_correct: int
    objective_total: int
    translation_score: float = Field(ge=0, le=10)
    essay_score: float = Field(ge=0, le=20)
    feedback: str
    section_scores: dict[str, dict[str, int]]
    performance_metrics: PerformanceMetrics


def sanitize_full_mock_exam_for_client(
    response: FullMockExamResponse,
) -> FullMockExamResponse:
    """Remove authoritative answers before an exam payload leaves the server."""
    payload = response.model_dump(mode="json")
    for section in payload.get("sections", []):
        if not isinstance(section, dict):
            continue
        for question in section.get("questions", []):
            if isinstance(question, dict):
                question.pop("correct_option_index", None)
                question.pop("correct_index", None)
                question.pop("answer", None)
                question.pop("explanation", None)
    return FullMockExamResponse.model_validate(payload)


class DiscourseResponse(BaseModel):
    article_with_blanks: str
    extracted_sentences: list[str]
    correct_mapping: dict[str, str]
    performance_metrics: PerformanceMetrics


class GSATReferencePaperSeedItem(BaseModel):
    year: int
    exam_type: str = Field(description="Grammar, Reading, or Discourse.")
    content: str
    json_structure: Any | None = None


class GSATSeedResponse(BaseModel):
    inserted: int
    total_reference_papers: int


class VocabAddRequest(BaseModel):
    word: str
    user_id: int = 1
    definition: str | None = None
    source_context: str | None = None


class VocabAddResponse(BaseModel):
    vocab_id: int
    word: str
    user_id: int
    interval: int
    repetitions: int
    ease_factor: float
    next_review_date: datetime


class VocabReviewItem(BaseModel):
    vocab_id: int
    word: str
    definition: str | None
    part_of_speech: str | None = None
    gsat_level: int | None = None
    gsat_frequency: int | None = None
    source_context: str | None
    progress_id: int
    interval: int
    repetitions: int
    ease_factor: float
    next_review_date: datetime


class VocabMnemonicRequest(BaseModel):
    word: str
    definition: str | None = None
    source_context: str | None = None
    app_mode: str = "engagement"


class VocabMnemonicResponse(BaseModel):
    word: str
    etymology: str
    taiwanese_mnemonic: str
    performance_metrics: PerformanceMetrics


class VocabUpdateProgressRequest(BaseModel):
    vocab_id: int
    quality: int
    action_id: str | None = Field(default=None, min_length=16, max_length=128)
    user_id: int = 1


class VocabUpdateProgressResponse(BaseModel):
    vocab_id: int
    user_id: int
    interval: int
    repetitions: int
    ease_factor: float
    next_review_date: datetime
    reward: RewardFeedback | None = None


class WeeklyReportRequest(BaseModel):
    persona: str = "Encouraging"
    app_mode: str = "engagement"


class WeeklyReportResponse(BaseModel):
    persona: str
    report: str
    vocab_reviews: int
    new_errors: int
    mastered_errors: int
    mission_tasks_completed: int = 0
    mission_tasks_total: int = 0
    top_error_concepts: list[str]
    performance_metrics: PerformanceMetrics


class WeeklyStudyPackCreateRequest(BaseModel):
    daily_minutes: int | None = Field(default=None, ge=5, le=30)
    week_start: date | None = None
    regenerate: bool = False


class WeeklyStudyPackResponse(BaseModel):
    id: str
    week_start: date
    pack_code: str
    daily_minutes: int
    status: str
    completed_days: list[int]
    day_count: int
    generated_at: datetime
    pdf_url: str


class WeeklyStudyPackCompleteRequest(BaseModel):
    pack_code: str = Field(min_length=6, max_length=12)
    completed_days: list[int] = Field(min_length=1, max_length=5)


class WeeklyStudyPackCompleteResponse(BaseModel):
    pack: WeeklyStudyPackResponse
    reward: RewardFeedback
    summary: RewardSummary


class GrammarLedgerSaveRequest(BaseModel):
    user_id: int = 1
    error_type: str = "grammar_quiz"
    original_sentence: str
    user_answer: str | None = None
    corrected_sentence: str | None = None
    explanation: str | None = None


class GrammarLedgerSaveResponse(BaseModel):
    id: int
    user_id: int
    error_type: str
    saved_at: datetime


class GrammarLedgerItem(BaseModel):
    id: int
    user_id: int
    error_type: str
    original_question: str
    user_answer: str | None = None
    correct_answer: str | None = None
    explanation: str | None = None
    occurrence_count: int
    is_mastered: bool
    created_at: datetime
    updated_at: datetime


class GrammarRedemptionRequest(BaseModel):
    user_id: int = 1
    app_mode: str = "engagement"


class GrammarRedemptionQuestion(BaseModel):
    concept: str
    question: str
    options: list[str]
    correct_option_index: int
    explanation: str
    ledger_error_ids: list[int] = Field(default_factory=list)


class GrammarRedemptionResponse(BaseModel):
    questions: list[GrammarRedemptionQuestion]
    performance_metrics: PerformanceMetrics


class GrammarLedgerMasteredResponse(BaseModel):
    id: int
    is_mastered: bool


class CorrectedMistake(BaseModel):
    original_question: str
    student_wrong_answer: str | None = None
    correct_answer: str
    explanation: str
    grammar_concept: str | None = None
    vocab_word: str | None = None
    ledger_error_id: int | None = None
    vocab_id: int | None = None


class DailyExpansionQuizItem(BaseModel):
    id: int
    concept: str
    question: str
    options: list[str]
    correct_option_index: int
    explanation: str | None = None
    due_date: datetime


class DailyExpansionQuizResponse(BaseModel):
    required: bool
    due_count: int
    questions: list[DailyExpansionQuizItem]


class DailyExpansionQuizSubmitRequest(BaseModel):
    answers: dict[int, int]


class DailyExpansionQuizSubmitResponse(BaseModel):
    completed: int
    correct: int
    total: int


class ExamUploadResponse(BaseModel):
    extracted_text: str
    analysis: str
    corrected_mistakes: list[CorrectedMistake] = Field(default_factory=list)
    expansion_quiz_count: int = 0
    expansion_job_id: str | None = None
    expansion_job_status: str | None = None
    performance_metrics: PerformanceMetrics


class BackgroundJobResponse(BaseModel):
    id: str
    job_type: str
    status: str
    attempts: int
    result: dict[str, Any] | None = None
    error_message: str | None = None
    created_at: datetime
    updated_at: datetime


def get_db() -> Generator[Session, None, None]:
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@app.get("/livez", tags=["system"])
def liveness_probe() -> dict[str, str]:
    """Answer whether this process is serving, and nothing else.

    The deployment health gate probes this rather than ``/health``. ``/health``
    executes a query, so a gate pointed at it reports the process as dead
    whenever the database is briefly unreachable, and holds back everything
    gated on it -- container startup ordering, a rollout, a restart -- for a
    dependency that is not the process. Readiness stays at ``/health``; this
    answers the narrower question a gate actually asks.

    The payload is a literal for the same reason: the route is unauthenticated,
    so anything it reads is published to anyone who probes it.
    """
    return {"status": "alive"}


@app.get("/health", tags=["system"])
def health_check(db: Session = Depends(get_db)) -> dict[str, Any]:
    db.execute(text("SELECT 1"))
    return {
        "status": "ok",
        "service": "GSAT_Max Backend",
        "environment": settings.app_env,
        "database": "reachable",
        "openai_configured": bool(OPENAI_API_KEY),
        "configured_ai_providers": [
            provider["name"] for provider in configured_ai_providers()
        ],
        "ollama_base_url": OLLAMA_BASE_URL,
    }


def ensure_user_schema() -> None:
    """Add auth/stat columns when an older SQLite file already exists."""
    if not DATABASE_URL.startswith("sqlite"):
        return

    with engine.begin() as connection:
        rows = connection.execute(text("PRAGMA table_info(users)"))
        column_names = {row[1] for row in rows}
        if not column_names:
            return
        if "password_hash" not in column_names:
            connection.execute(text("ALTER TABLE users ADD COLUMN password_hash TEXT"))
        if "essays_written" not in column_names:
            connection.execute(
                text("ALTER TABLE users ADD COLUMN essays_written INTEGER NOT NULL DEFAULT 0")
            )
        if "grammar_score_total" not in column_names:
            connection.execute(
                text(
                    "ALTER TABLE users ADD COLUMN "
                    "grammar_score_total FLOAT NOT NULL DEFAULT 0.0"
                )
            )
        if "grammar_score_count" not in column_names:
            connection.execute(
                text(
                    "ALTER TABLE users ADD COLUMN "
                    "grammar_score_count INTEGER NOT NULL DEFAULT 0"
                )
            )
        if "last_login_date" not in column_names:
            connection.execute(text("ALTER TABLE users ADD COLUMN last_login_date DATETIME"))
        if "current_streak" not in column_names:
            connection.execute(
                text("ALTER TABLE users ADD COLUMN current_streak INTEGER NOT NULL DEFAULT 0")
            )
        if "daily_ai_quota" not in column_names:
            connection.execute(
                text("ALTER TABLE users ADD COLUMN daily_ai_quota INTEGER NOT NULL DEFAULT 20")
            )
        if "quota_reset_date" not in column_names:
            connection.execute(text("ALTER TABLE users ADD COLUMN quota_reset_date DATETIME"))
        if "is_pro" not in column_names:
            connection.execute(
                text("ALTER TABLE users ADD COLUMN is_pro BOOLEAN NOT NULL DEFAULT 0")
            )
        if "has_completed_onboarding" not in column_names:
            connection.execute(
                text(
                    "ALTER TABLE users ADD COLUMN "
                    "has_completed_onboarding BOOLEAN NOT NULL DEFAULT 0"
                )
            )
        if "target_exam_date" not in column_names:
            connection.execute(text("ALTER TABLE users ADD COLUMN target_exam_date DATETIME"))
        if "is_admin" not in column_names:
            connection.execute(
                text("ALTER TABLE users ADD COLUMN is_admin BOOLEAN NOT NULL DEFAULT 0")
            )
        if "email_verified_at" not in column_names:
            connection.execute(text("ALTER TABLE users ADD COLUMN email_verified_at DATETIME"))
        for column_name in (
            "skill_vocabulary",
            "skill_grammar",
            "skill_reading",
            "skill_writing",
        ):
            if column_name not in column_names:
                connection.execute(
                    text(f"ALTER TABLE users ADD COLUMN {column_name} FLOAT NOT NULL DEFAULT 0.0")
                )


def ensure_vocabulary_schema() -> None:
    """Add GSAT metadata columns when an older SQLite file already exists."""
    if not DATABASE_URL.startswith("sqlite"):
        return

    with engine.begin() as connection:
        rows = connection.execute(text("PRAGMA table_info(vocabulary)"))
        column_names = {row[1] for row in rows}
        if not column_names:
            return
        if "part_of_speech" not in column_names:
            connection.execute(text("ALTER TABLE vocabulary ADD COLUMN part_of_speech VARCHAR(40)"))
        if "gsat_level" not in column_names:
            connection.execute(text("ALTER TABLE vocabulary ADD COLUMN gsat_level INTEGER"))
        if "gsat_frequency" not in column_names:
            connection.execute(text("ALTER TABLE vocabulary ADD COLUMN gsat_frequency INTEGER"))


def ensure_grammar_concept_bank_schema() -> None:
    """Create grammar concept bank table for older SQLite files."""
    if not DATABASE_URL.startswith("sqlite"):
        return

    with engine.begin() as connection:
        connection.execute(
            text(
                """
                CREATE TABLE IF NOT EXISTS grammar_concept_bank (
                    id INTEGER NOT NULL PRIMARY KEY,
                    name VARCHAR(120) NOT NULL UNIQUE,
                    category VARCHAR(120),
                    description TEXT,
                    example_sentence TEXT,
                    gsat_level INTEGER,
                    created_at DATETIME NOT NULL
                )
                """
            )
        )
        for index_name, column_name in (
            ("ix_grammar_concept_bank_name", "name"),
            ("ix_grammar_concept_bank_category", "category"),
            ("ix_grammar_concept_bank_gsat_level", "gsat_level"),
        ):
            connection.execute(
                text(
                    f"CREATE INDEX IF NOT EXISTS {index_name} "
                    f"ON grammar_concept_bank ({column_name})"
                )
            )


def ensure_grammar_ledger_schema() -> None:
    """Add new demo columns when an older SQLite file already exists."""
    if not DATABASE_URL.startswith("sqlite"):
        return

    with engine.begin() as connection:
        rows = connection.execute(text("PRAGMA table_info(grammar_error_ledger)"))
        column_names = {row[1] for row in rows}
        if not column_names:
            return
        if "user_answer" not in column_names:
            connection.execute(
                text("ALTER TABLE grammar_error_ledger ADD COLUMN user_answer TEXT")
            )
        if "is_mastered" not in column_names:
            connection.execute(
                text(
                    "ALTER TABLE grammar_error_ledger "
                    "ADD COLUMN is_mastered BOOLEAN NOT NULL DEFAULT 0"
                )
            )


def ensure_daily_expansion_quiz_schema() -> None:
    """Create expansion quiz table for older SQLite files."""
    if not DATABASE_URL.startswith("sqlite"):
        return

    with engine.begin() as connection:
        connection.execute(
            text(
                """
                CREATE TABLE IF NOT EXISTS daily_expansion_quizzes (
                    id INTEGER NOT NULL PRIMARY KEY,
                    user_id INTEGER NOT NULL,
                    grammar_error_id INTEGER,
                    concept VARCHAR(120) NOT NULL,
                    question TEXT NOT NULL,
                    options_json TEXT NOT NULL,
                    correct_option_index INTEGER NOT NULL DEFAULT 0,
                    explanation TEXT,
                    due_date DATETIME NOT NULL,
                    completed_at DATETIME,
                    created_at DATETIME NOT NULL,
                    FOREIGN KEY(user_id) REFERENCES users (id),
                    FOREIGN KEY(grammar_error_id) REFERENCES grammar_error_ledger (id)
                )
                """
            )
        )
        for index_name, column_name in (
            ("ix_daily_expansion_quizzes_user_id", "user_id"),
            ("ix_daily_expansion_quizzes_due_date", "due_date"),
            ("ix_daily_expansion_quizzes_concept", "concept"),
            ("ix_daily_expansion_quizzes_grammar_error_id", "grammar_error_id"),
        ):
            connection.execute(
                text(
                    f"CREATE INDEX IF NOT EXISTS {index_name} "
                    f"ON daily_expansion_quizzes ({column_name})"
                )
            )
        rows = connection.execute(text("PRAGMA table_info(daily_expansion_quizzes)"))
        column_names = {row[1] for row in rows}
        if "source_job_id" not in column_names:
            connection.execute(
                text("ALTER TABLE daily_expansion_quizzes ADD COLUMN source_job_id VARCHAR(64)")
            )
            connection.execute(
                text(
                    "CREATE INDEX IF NOT EXISTS ix_daily_expansion_quizzes_source_job_id "
                    "ON daily_expansion_quizzes (source_job_id)"
                )
            )


def ensure_user(db: Session, user_id: int = 1) -> User:
    user = db.get(User, user_id)
    if user:
        return user

    user = User(
        id=user_id,
        email=DEFAULT_USER_EMAIL if user_id == 1 else f"user-{user_id}@student.local",
        display_name="Demo Student" if user_id == 1 else f"Student {user_id}",
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def normalize_email(email: str) -> str:
    normalized = email.strip().lower()
    if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", normalized):
        raise HTTPException(status_code=422, detail="Enter a valid email address.")
    return normalized


def hash_password(password: str) -> str:
    if len(password) < 8:
        raise HTTPException(status_code=422, detail="Password must be at least 8 characters.")
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt.encode("utf-8"),
        PASSWORD_HASH_ITERATIONS,
    ).hex()
    return f"pbkdf2_sha256${PASSWORD_HASH_ITERATIONS}${salt}${digest}"


def verify_password(password: str, stored_hash: str | None) -> bool:
    if not stored_hash:
        return False
    try:
        algorithm, iterations_text, salt, expected = stored_hash.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        digest = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            salt.encode("utf-8"),
            int(iterations_text),
        ).hex()
        return hmac.compare_digest(digest, expected)
    except (ValueError, TypeError):
        return False


def password_hash_is_outdated(stored_hash: str | None) -> bool:
    """True when a verified hash was made with a weaker cost than we now use."""
    if not stored_hash:
        return False
    try:
        algorithm, iterations_text, _salt, _expected = stored_hash.split("$", 3)
    except ValueError:
        return False
    if algorithm != "pbkdf2_sha256":
        return True
    try:
        return int(iterations_text) < PASSWORD_HASH_ITERATIONS
    except ValueError:
        return True


def maybe_upgrade_password_hash(user: User, password: str) -> None:
    """Re-hash at the current cost, once, right after a successful login.

    The plaintext is only available here, so this is the sole moment an
    already-stored hash can be strengthened without forcing a password reset.
    """
    if password_hash_is_outdated(user.password_hash):
        user.password_hash = hash_password(password)


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(f"{value}{padding}")


def create_access_token(user: User) -> str:
    now = int(time.time())
    payload = {
        "sub": str(user.id),
        "email": user.email,
        "typ": "access",
        "iat": now,
        "exp": now + JWT_EXPIRE_MINUTES * 60,
    }
    header = {"alg": JWT_ALGORITHM, "typ": "JWT"}
    signing_input = ".".join(
        [
            _b64url_encode(json.dumps(header, separators=(",", ":")).encode("utf-8")),
            _b64url_encode(json.dumps(payload, separators=(",", ":")).encode("utf-8")),
        ]
    )
    signature = hmac.new(
        JWT_SECRET_KEY.encode("utf-8"),
        signing_input.encode("ascii"),
        hashlib.sha256,
    ).digest()
    return f"{signing_input}.{_b64url_encode(signature)}"


def decode_access_token(token: str) -> dict[str, Any]:
    try:
        header_part, payload_part, signature_part = token.split(".", 2)
    except ValueError as exc:
        raise HTTPException(status_code=401, detail="Invalid token.") from exc

    signing_input = f"{header_part}.{payload_part}"
    expected_signature = hmac.new(
        JWT_SECRET_KEY.encode("utf-8"),
        signing_input.encode("ascii"),
        hashlib.sha256,
    ).digest()
    try:
        supplied_signature = _b64url_decode(signature_part)
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Invalid token signature.") from exc
    if not hmac.compare_digest(expected_signature, supplied_signature):
        raise HTTPException(status_code=401, detail="Invalid token signature.")

    try:
        header = json.loads(_b64url_decode(header_part))
        payload = json.loads(_b64url_decode(payload_part))
    except (json.JSONDecodeError, ValueError) as exc:
        raise HTTPException(status_code=401, detail="Invalid token payload.") from exc

    if header.get("alg") != JWT_ALGORITHM:
        raise HTTPException(status_code=401, detail="Unsupported token algorithm.")
    if _safe_int(payload.get("exp")) < int(time.time()):
        raise HTTPException(status_code=401, detail="Token has expired.")
    if payload.get("typ") != "access":
        raise HTTPException(status_code=401, detail="Invalid token type.")
    return payload


def get_current_user(
    authorization: str | None = Header(default=None),
    db: Session = Depends(get_db),
) -> User:
    if not authorization:
        raise HTTPException(status_code=401, detail="Missing Authorization header.")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(status_code=401, detail="Use Bearer token authentication.")

    payload = decode_access_token(token)
    user_id = _safe_int(payload.get("sub"), -1)
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="Token user no longer exists.")
    return user


def get_admin_user(current_user: User = Depends(get_current_user)) -> User:
    if not bool(current_user.is_admin):
        raise HTTPException(status_code=403, detail="Administrator access required.")
    return current_user


def enforce_rate_limit(
    key: str,
    *,
    limit: int,
    window_seconds: int,
) -> None:
    now = time.monotonic()
    cutoff = now - window_seconds
    with _RATE_LIMIT_LOCK:
        bucket = _RATE_LIMIT_BUCKETS[key]
        while bucket and bucket[0] <= cutoff:
            bucket.popleft()
        if len(bucket) >= limit:
            retry_after = max(1, int(window_seconds - (now - bucket[0])))
            raise HTTPException(
                status_code=429,
                detail="Too many requests. Please try again later.",
                headers={"Retry-After": str(retry_after)},
            )
        bucket.append(now)


def check_ai_quota(
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> User:
    enforce_rate_limit(
        f"ai:{current_user.id}:{request.url.path}",
        limit=12 if current_user.is_pro else 6,
        window_seconds=60,
    )
    if bool(current_user.is_pro):
        return current_user

    today = datetime.utcnow().date()
    reset_date = current_user.quota_reset_date.date() if current_user.quota_reset_date else None

    if reset_date is None or reset_date < today:
        current_user.daily_ai_quota = 20
        current_user.quota_reset_date = datetime.utcnow()

    if int(current_user.daily_ai_quota or 0) <= 0:
        db.commit()
        raise HTTPException(
            status_code=403,
            detail="Daily AI generation limit reached.",
        )

    current_user.daily_ai_quota = int(current_user.daily_ai_quota or 0) - 1
    db.commit()
    db.refresh(current_user)
    return current_user


def _refresh_token_hash(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def create_refresh_token(db: Session, user: User) -> str:
    raw_token = secrets.token_urlsafe(48)
    record = RefreshToken(
        user_id=user.id,
        token_hash=_refresh_token_hash(raw_token),
        jti=secrets.token_hex(24),
        expires_at=datetime.utcnow() + timedelta(days=settings.refresh_token_expire_days),
    )
    db.add(record)
    db.flush()
    return raw_token


def user_response(user: User) -> AuthUserResponse:
    return AuthUserResponse(
        user_id=user.id,
        email=user.email,
        display_name=user.display_name,
        current_streak=int(user.current_streak or 0),
        has_completed_onboarding=bool(user.has_completed_onboarding),
        is_pro=bool(user.is_pro),
        email_verified=user.email_verified_at is not None,
    )


def auth_response_for_user(user: User, db: Session) -> AuthTokenResponse:
    refresh_token = create_refresh_token(db, user)
    db.commit()
    return AuthTokenResponse(
        access_token=create_access_token(user),
        refresh_token=refresh_token,
        expires_in=JWT_EXPIRE_MINUTES * 60,
        user_id=user.id,
        email=user.email,
        display_name=user.display_name,
        current_streak=int(user.current_streak or 0),
        has_completed_onboarding=bool(user.has_completed_onboarding),
        is_pro=bool(user.is_pro),
    )


def update_login_streak(user: User, db: Session) -> None:
    preference = get_or_create_learning_preference(db, user.id)
    today = _local_today(preference)
    previous_login = user.last_login_date.date() if user.last_login_date else None

    if previous_login == today:
        user.current_streak = max(1, int(user.current_streak or 1))
    elif previous_login == today - timedelta(days=1):
        user.current_streak = int(user.current_streak or 0) + 1
    elif previous_login == today - timedelta(days=2):
        reward_state = get_or_create_reward_state(db, user.id, preference=preference)
        if preference.gentle_streak_enabled and int(reward_state.streak_shields or 0) > 0:
            reward_state.streak_shields -= 1
            reward_state.comeback_count = int(reward_state.comeback_count or 0) + 1
            user.current_streak = max(1, int(user.current_streak or 1))
        else:
            user.current_streak = 1
    else:
        user.current_streak = 1

    user.last_login_date = datetime.combine(today, datetime.min.time())


def create_email_action_token(
    db: Session,
    *,
    user: User,
    purpose: str,
    lifetime_minutes: int,
) -> str:
    now = datetime.utcnow()
    previous_tokens = db.scalars(
        select(EmailActionToken).where(
            EmailActionToken.user_id == user.id,
            EmailActionToken.purpose == purpose,
            EmailActionToken.used_at.is_(None),
        )
    ).all()
    for previous in previous_tokens:
        previous.used_at = now
    raw_token = secrets.token_urlsafe(48)
    db.add(
        EmailActionToken(
            user_id=user.id,
            purpose=purpose,
            token_hash=hashlib.sha256(raw_token.encode("utf-8")).hexdigest(),
            expires_at=now + timedelta(minutes=lifetime_minutes),
        )
    )
    db.commit()
    return raw_token


def consume_email_action_token(
    db: Session,
    *,
    raw_token: str,
    purpose: str,
) -> tuple[EmailActionToken, User]:
    record = db.scalar(
        select(EmailActionToken).where(
            EmailActionToken.token_hash
            == hashlib.sha256(raw_token.encode("utf-8")).hexdigest(),
            EmailActionToken.purpose == purpose,
        )
    )
    now = datetime.utcnow()
    if record is None or record.used_at is not None or record.expires_at <= now:
        raise HTTPException(status_code=400, detail="Action token is invalid or expired.")
    user = db.get(User, record.user_id)
    if user is None:
        raise HTTPException(status_code=400, detail="Action token user no longer exists.")
    record.used_at = now
    return record, user


def email_action_response(raw_token: str | None = None) -> EmailActionResponse:
    expose_debug_token = settings.app_env.lower() in {"development", "test"}
    return EmailActionResponse(
        debug_token=raw_token if expose_debug_token else None,
    )


@app.post("/auth/register", response_model=AuthTokenResponse)
def register_user(
    http_request: Request,
    request: AuthRegisterRequest,
    db: Session = Depends(get_db),
) -> AuthTokenResponse:
    client_host = http_request.client.host if http_request.client else "unknown"
    enforce_rate_limit(f"register:{client_host}", limit=5, window_seconds=900)
    email = normalize_email(request.email)
    existing_user = db.scalar(select(User).where(User.email == email))
    if existing_user is not None:
        raise HTTPException(status_code=409, detail="Email is already registered.")

    user = User(
        email=email,
        display_name=(request.display_name or email.split("@")[0]).strip(),
        password_hash=hash_password(request.password),
        current_streak=1,
        last_login_date=datetime.combine(_local_today(), datetime.min.time()),
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return auth_response_for_user(user, db)


@app.post("/auth/login", response_model=AuthTokenResponse)
def login_user(
    http_request: Request,
    request: AuthLoginRequest,
    db: Session = Depends(get_db),
) -> AuthTokenResponse:
    client_host = http_request.client.host if http_request.client else "unknown"
    enforce_rate_limit(f"login:{client_host}", limit=10, window_seconds=300)
    email = normalize_email(request.email)
    user = db.scalar(select(User).where(User.email == email))
    if user is None or not verify_password(request.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid email or password.")
    maybe_upgrade_password_hash(user, request.password)
    update_login_streak(user, db)
    db.commit()
    db.refresh(user)
    return auth_response_for_user(user, db)


@app.post("/auth/email-verification/request", response_model=EmailActionResponse)
def request_email_verification(
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> EmailActionResponse:
    if current_user.email_verified_at is not None:
        return email_action_response()
    raw_token = create_email_action_token(
        db,
        user=current_user,
        purpose="verify_email",
        lifetime_minutes=24 * 60,
    )
    try:
        get_email_provider().send_action_email(
            recipient=current_user.email,
            subject="Verify your GSAT_Max email",
            action_token=raw_token,
            action_url=(
                f"{settings.public_app_url}/verify-email?token={quote(raw_token)}"
            ),
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return email_action_response(raw_token)


@app.post("/auth/email-verification/confirm", response_model=AuthUserResponse)
def confirm_email_verification(
    request: EmailActionConfirmRequest,
    db: Session = Depends(get_db),
) -> AuthUserResponse:
    _, user = consume_email_action_token(
        db,
        raw_token=request.token,
        purpose="verify_email",
    )
    user.email_verified_at = datetime.utcnow()
    db.commit()
    db.refresh(user)
    return user_response(user)


@app.post("/auth/password-reset/request", response_model=EmailActionResponse)
def request_password_reset(
    http_request: Request,
    request: EmailActionRequest,
    db: Session = Depends(get_db),
) -> EmailActionResponse:
    client_host = http_request.client.host if http_request.client else "unknown"
    enforce_rate_limit(f"password-reset:{client_host}", limit=5, window_seconds=900)
    email = normalize_email(request.email or "")
    user = db.scalar(select(User).where(User.email == email))
    if user is None:
        return email_action_response()
    raw_token = create_email_action_token(
        db,
        user=user,
        purpose="reset_password",
        lifetime_minutes=30,
    )
    try:
        get_email_provider().send_action_email(
            recipient=user.email,
            subject="Reset your GSAT_Max password",
            action_token=raw_token,
            action_url=(
                f"{settings.public_app_url}/reset-password?token={quote(raw_token)}"
            ),
        )
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return email_action_response(raw_token)


@app.post("/auth/password-reset/confirm", response_model=EmailActionResponse)
def confirm_password_reset(
    request: PasswordResetConfirmRequest,
    db: Session = Depends(get_db),
) -> EmailActionResponse:
    _, user = consume_email_action_token(
        db,
        raw_token=request.token,
        purpose="reset_password",
    )
    user.password_hash = hash_password(request.new_password)
    now = datetime.utcnow()
    for refresh_token in db.scalars(
        select(RefreshToken).where(
            RefreshToken.user_id == user.id,
            RefreshToken.revoked_at.is_(None),
        )
    ).all():
        refresh_token.revoked_at = now
    db.commit()
    return email_action_response()


@app.post("/auth/refresh", response_model=AuthTokenResponse)
def refresh_auth_session(
    request: AuthRefreshRequest,
    db: Session = Depends(get_db),
) -> AuthTokenResponse:
    record = db.scalar(
        select(RefreshToken).where(
            RefreshToken.token_hash == _refresh_token_hash(request.refresh_token)
        )
    )
    now = datetime.utcnow()
    if record is None or record.revoked_at is not None or record.expires_at <= now:
        raise HTTPException(status_code=401, detail="Refresh token is invalid or expired.")
    user = db.get(User, record.user_id)
    if user is None:
        raise HTTPException(status_code=401, detail="Token user no longer exists.")

    record.revoked_at = now
    replacement = secrets.token_urlsafe(48)
    replacement_jti = secrets.token_hex(24)
    record.replaced_by_jti = replacement_jti
    db.add(
        RefreshToken(
            user_id=user.id,
            token_hash=_refresh_token_hash(replacement),
            jti=replacement_jti,
            expires_at=now + timedelta(days=settings.refresh_token_expire_days),
        )
    )
    db.commit()
    return AuthTokenResponse(
        access_token=create_access_token(user),
        refresh_token=replacement,
        expires_in=JWT_EXPIRE_MINUTES * 60,
        user_id=user.id,
        email=user.email,
        display_name=user.display_name,
        current_streak=int(user.current_streak or 0),
        has_completed_onboarding=bool(user.has_completed_onboarding),
        is_pro=bool(user.is_pro),
    )


@app.post("/auth/logout")
def logout_auth_session(
    request: AuthLogoutRequest,
    db: Session = Depends(get_db),
) -> dict[str, str]:
    record = db.scalar(
        select(RefreshToken).where(
            RefreshToken.token_hash == _refresh_token_hash(request.refresh_token)
        )
    )
    if record is not None and record.revoked_at is None:
        record.revoked_at = datetime.utcnow()
        db.commit()
    return {"status": "logged_out"}


@app.get("/auth/me", response_model=AuthUserResponse)
def get_authenticated_profile(
    current_user: User = Depends(get_current_user),
) -> AuthUserResponse:
    return user_response(current_user)


@app.post("/user/upgrade")
def reject_client_side_upgrade(
    current_user: User = Depends(get_current_user),
) -> dict[str, str]:
    raise HTTPException(
        status_code=403,
        detail=(
            "Pro entitlement cannot be granted by the client. "
            "Complete a verified RevenueCat purchase instead."
        ),
    )


@app.get("/user/entitlement")
def get_user_entitlement(
    current_user: User = Depends(get_current_user),
) -> dict[str, Any]:
    return {"is_pro": bool(current_user.is_pro), "source": "server"}


@app.post("/integrations/revenuecat/webhook")
async def revenuecat_webhook(
    request: Request,
    authorization: str | None = Header(default=None),
    db: Session = Depends(get_db),
) -> dict[str, str]:
    expected = settings.revenuecat_webhook_auth
    if not expected:
        raise HTTPException(status_code=503, detail="RevenueCat webhook is not configured.")
    supplied = (authorization or "").removeprefix("Bearer ").strip()
    if not supplied or not hmac.compare_digest(supplied, expected):
        raise HTTPException(status_code=401, detail="Invalid RevenueCat webhook authorization.")

    payload = await request.json()
    event = payload.get("event", {}) if isinstance(payload, dict) else {}
    if not isinstance(event, dict):
        raise HTTPException(status_code=422, detail="RevenueCat event payload is invalid.")
    app_user_id = str(event.get("app_user_id") or "").strip()
    user_id = _safe_int(app_user_id, -1)
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="RevenueCat app user was not found.")

    event_type = str(event.get("type") or "").upper()
    active_types = {
        "INITIAL_PURCHASE",
        "RENEWAL",
        "PRODUCT_CHANGE",
        "UNCANCELLATION",
        "SUBSCRIPTION_EXTENDED",
        "TEMPORARY_ENTITLEMENT_GRANT",
        "NON_RENEWING_PURCHASE",
    }
    inactive_types = {"EXPIRATION"}
    if event_type in active_types:
        user.is_pro = True
        user.daily_ai_quota = 20
        user.quota_reset_date = datetime.utcnow()
    elif event_type in inactive_types:
        user.is_pro = False
    else:
        return {"status": "ignored"}
    db.commit()
    return {"status": "processed"}


@app.delete("/user/account")
def delete_user_account(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> dict[str, str]:
    user = db.get(User, current_user.id)
    if user is None:
        raise HTTPException(status_code=401, detail="Token user no longer exists.")

    db.delete(user)
    db.commit()
    return {"status": "deleted"}


def calculate_sm2(
    quality: int,
    interval: int,
    repetitions: int,
    ease_factor: float,
) -> dict[str, Any]:
    if quality < 0 or quality > 5:
        raise ValueError("quality must be between 0 and 5")

    ease_factor = max(ease_factor, 1.3)

    if quality < 3:
        repetitions = 0
        interval = 1
    else:
        if repetitions == 0:
            interval = 1
        elif repetitions == 1:
            interval = 6
        else:
            interval = max(1, round(interval * ease_factor))

        repetitions += 1

    ease_factor = ease_factor + (
        0.1 - (5 - quality) * (0.08 + (5 - quality) * 0.02)
    )
    ease_factor = max(1.3, ease_factor)
    next_review_date = datetime.utcnow() + timedelta(days=interval)

    return {
        "interval": interval,
        "repetitions": repetitions,
        "ease_factor": round(ease_factor, 2),
        "next_review_date": next_review_date,
    }


def normalize_word(word: str) -> str:
    normalized = "".join(char for char in word.lower().strip() if char.isalpha() or char in "-'")
    normalized = normalized.strip("-'")
    if not normalized:
        raise HTTPException(status_code=422, detail="word must contain English letters")
    return normalized


def normalize_concept(value: str | None, fallback: str = "exam_mistake") -> str:
    text_value = (value or "").strip().lower()
    text_value = re.sub(r"[^a-z0-9]+", "_", text_value).strip("_")
    return text_value or fallback


def parse_json_array_from_text(text_value: str) -> list[Any]:
    stripped = text_value.strip()
    candidates = [stripped]
    array_match = re.search(r"\[[\s\S]*\]", stripped)
    if array_match:
        candidates.insert(0, array_match.group(0))

    for candidate in candidates:
        try:
            decoded = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(decoded, list):
            return decoded
        if isinstance(decoded, dict):
            value = (
                decoded.get("corrected_mistakes")
                or decoded.get("mistakes")
                or decoded.get("items")
            )
            if isinstance(value, list):
                return value
    return []


def safe_options(value: Any) -> list[str]:
    if isinstance(value, list):
        options = [str(option).strip() for option in value if str(option).strip()]
    else:
        options = []
    fallback_options = [
        "This option correctly applies the target concept.",
        "This option contains a common learner error.",
        "This option changes the meaning of the sentence.",
        "This option uses unnatural English.",
    ]
    while len(options) < 4:
        options.append(fallback_options[len(options)])
    return options[:4]


def upsert_vocab_progress_from_mistake(
    db: Session,
    user_id: int,
    vocab_word: str | None,
    explanation: str,
    source_context: str,
) -> int | None:
    if not vocab_word:
        return None
    try:
        word = normalize_word(vocab_word)
    except HTTPException:
        return None

    vocabulary = db.scalar(select(Vocabulary).where(Vocabulary.word == word))
    if vocabulary is None:
        vocabulary = Vocabulary(
            word=word,
            definition=_clip_text(explanation, 500),
            source_context=_clip_text(source_context, 500),
        )
        db.add(vocabulary)
        db.flush()
    else:
        if not vocabulary.definition and explanation:
            vocabulary.definition = _clip_text(explanation, 500)
        if not vocabulary.source_context and source_context:
            vocabulary.source_context = _clip_text(source_context, 500)

    progress = db.scalar(
        select(UserVocabProgress).where(
            UserVocabProgress.user_id == user_id,
            UserVocabProgress.vocab_id == vocabulary.id,
        )
    )
    if progress is None:
        progress = UserVocabProgress(
            user_id=user_id,
            vocab_id=vocabulary.id,
            interval=0,
            repetitions=0,
            ease_factor=2.3,
            next_review_date=datetime.utcnow(),
        )
        db.add(progress)
    else:
        progress.interval = 0
        progress.repetitions = 0
        progress.ease_factor = min(float(progress.ease_factor or 2.5), 2.3)
        progress.next_review_date = datetime.utcnow()

    db.flush()
    return vocabulary.id


def daily_expansion_item_to_response(item: DailyExpansionQuiz) -> DailyExpansionQuizItem:
    try:
        decoded_options = json.loads(item.options_json)
    except json.JSONDecodeError:
        decoded_options = []
    options = safe_options(decoded_options)
    correct_index = item.correct_option_index
    if correct_index < 0 or correct_index >= len(options):
        correct_index = 0
    return DailyExpansionQuizItem(
        id=item.id,
        concept=item.concept,
        question=item.question,
        options=options,
        correct_option_index=correct_index,
        explanation=item.explanation,
        due_date=item.due_date,
    )


INITIAL_EASY_GSAT_WORDS = [
    ("benefit", "好處；利益", "Daily reading has a clear benefit for exam preparation."),
    ("increase", "增加", "The number of students using digital tools may increase."),
    ("culture", "文化", "Language learning helps students understand another culture."),
    ("local", "當地的", "The local library offers free English magazines."),
    ("provide", "提供", "Teachers provide feedback after each writing task."),
    ("improve", "改善；進步", "Short daily practice can improve vocabulary memory."),
    ("reason", "原因", "The reason for the change was clearly explained."),
    ("result", "結果", "The result showed steady progress."),
    ("support", "支持", "Parents can support students by creating a quiet study space."),
    ("modern", "現代的", "Modern technology makes review more personal."),
]

INITIAL_HARD_GSAT_WORDS = [
    ("substantial", "大量的；重要的", "The plan produced substantial progress over time."),
    ("controversial", "有爭議的", "The policy became controversial among students."),
    ("sustainable", "永續的", "A sustainable habit is easier to maintain during exams."),
    ("perspective", "觀點", "Reading gives students a broader perspective."),
    ("consequence", "後果；結果", "Every decision has a possible consequence."),
    ("phenomenon", "現象", "Online learning is now a common phenomenon."),
    ("approximately", "大約", "The article contains approximately three hundred words."),
    ("interpret", "解讀；詮釋", "Students must interpret data carefully in chart writing."),
    ("significant", "顯著的；重要的", "A significant difference appeared after four weeks."),
    ("nevertheless", "然而；儘管如此", "The task was difficult; nevertheless, she finished it."),
]


def _safe_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(value)
    except (TypeError, ValueError):
        return default


def _safe_string(value: Any, default: str = "") -> str:
    if value is None:
        return default
    text = str(value).strip()
    return text or default


def extract_named_score(text_value: str, score_name: str) -> float | None:
    pattern = rf"{re.escape(score_name)}\s*[:\-]?\s*(\d+(?:\.\d+)?)\s*/\s*5"
    match = re.search(pattern, text_value, flags=re.IGNORECASE)
    if not match:
        return None
    score = float(match.group(1))
    return max(0.0, min(5.0, score))


def parse_json_object_from_text(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if not stripped:
        return {}

    try:
        parsed = json.loads(stripped)
        return parsed if isinstance(parsed, dict) else {}
    except json.JSONDecodeError:
        start = stripped.find("{")
        end = stripped.rfind("}")
        if start == -1 or end == -1 or end <= start:
            return {}

    try:
        parsed = json.loads(stripped[start : end + 1])
        return parsed if isinstance(parsed, dict) else {}
    except json.JSONDecodeError:
        return {}


def parse_writing_evaluation(text_value: str) -> WritingEvaluation:
    parsed = parse_json_object_from_text(text_value)
    if not parsed:
        raise ValueError("AI did not return a JSON object.")
    evaluation = WritingEvaluation(**parsed)
    score_sum = (
        evaluation.scores.content
        + evaluation.scores.organization
        + evaluation.scores.grammar
        + evaluation.scores.vocabulary
    )
    if abs(evaluation.total_score - score_sum) > 0.11:
        evaluation.total_score = round(score_sum, 1)
    evaluation.max_score = 20
    evaluation.rubric_version = "gsat-writing-v1"
    return evaluation


def parse_mock_exam_subjective_evaluation(
    text_value: str,
) -> FullMockExamSubjectiveEvaluation:
    parsed = parse_json_object_from_text(text_value)
    if not parsed:
        raise ValueError("AI did not return a JSON object.")
    evaluation = FullMockExamSubjectiveEvaluation(**parsed)
    evaluation.rubric_version = "gsat-mock-v1"
    return evaluation


def build_ai_cache_hash(params: dict[str, Any]) -> str:
    def sanitize(value: Any) -> Any:
        if isinstance(value, str):
            return " ".join(value.strip().lower().split())
        if isinstance(value, dict):
            return {str(key): sanitize(value[key]) for key in sorted(value)}
        if isinstance(value, list):
            return [sanitize(item) for item in value]
        return value

    sanitized_payload = json.dumps(
        sanitize(params),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(sanitized_payload.encode("utf-8")).hexdigest()


def model_to_cache_json(model: BaseModel) -> str:
    if hasattr(model, "model_dump"):
        data = model.model_dump(mode="json")
    else:
        data = model.dict()
    return json.dumps(data, ensure_ascii=False, default=str)


def mark_cached_response(data: dict[str, Any]) -> dict[str, Any]:
    metrics = data.get("performance_metrics")
    if isinstance(metrics, dict):
        metrics["cached"] = True
    else:
        data["performance_metrics"] = {
            "total_time_seconds": 0.0,
            "tokens_per_second": 0.0,
            "total_tokens": 0,
            "cached": True,
        }
    return data


def get_cached_ai_response(
    db: Session,
    endpoint: str,
    cache_params: dict[str, Any],
) -> dict[str, Any] | None:
    prompt_hash = build_ai_cache_hash({"endpoint": endpoint, **cache_params})
    valid_after = datetime.utcnow() - timedelta(days=7)
    cache_entry = db.scalar(
        select(AICache)
        .where(
            AICache.endpoint == endpoint,
            AICache.prompt_hash == prompt_hash,
            AICache.created_at >= valid_after,
        )
        .order_by(AICache.created_at.desc())
    )
    if cache_entry is None:
        return None

    try:
        cached_data = json.loads(cache_entry.response_json)
    except json.JSONDecodeError:
        return None
    return mark_cached_response(cached_data if isinstance(cached_data, dict) else {})


def save_ai_response_cache(
    db: Session,
    endpoint: str,
    cache_params: dict[str, Any],
    response_model: BaseModel,
) -> None:
    prompt_hash = build_ai_cache_hash({"endpoint": endpoint, **cache_params})
    cache_entry = AICache(
        prompt_hash=prompt_hash,
        endpoint=endpoint,
        response_json=model_to_cache_json(response_model),
    )
    db.add(cache_entry)
    db.commit()


def normalize_gsat_exam_type(exam_type: str) -> str:
    normalized = exam_type.strip().lower()
    aliases = {
        "grammar": "Grammar",
        "文法": "Grammar",
        "reading": "Reading",
        "閱讀": "Reading",
        "discourse": "Discourse",
        "篇章結構": "Discourse",
    }
    if normalized not in aliases:
        raise HTTPException(
            status_code=422,
            detail="exam_type must be one of Grammar, Reading, or Discourse.",
        )
    return aliases[normalized]


def serialize_json_structure(value: Any | None) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        return value.strip() or None
    return json.dumps(value, ensure_ascii=False, indent=2)


def fetch_gsat_few_shot_examples(
    db: Session,
    exam_type: str,
    limit: int = 2,
) -> list[GSATReferencePaper]:
    normalized_exam_type = normalize_gsat_exam_type(exam_type)
    return list(
        db.scalars(
            select(GSATReferencePaper)
            .where(GSATReferencePaper.exam_type == normalized_exam_type)
            .order_by(func.random())
            .limit(limit)
        ).all()
    )


def gsat_reference_signature(references: list[GSATReferencePaper]) -> list[dict[str, Any]]:
    return [
        {
            "id": reference.id,
            "year": reference.year,
            "exam_type": reference.exam_type,
            "content_hash": hashlib.sha256(
                f"{reference.content}|{reference.json_structure or ''}".encode("utf-8")
            ).hexdigest()[:16],
        }
        for reference in references
    ]


def build_gsat_few_shot_prompt(
    exam_type: str,
    references: list[GSATReferencePaper],
) -> str:
    if not references:
        return (
            "Few-Shot Examples: No seeded GSAT reference papers are available yet. "
            "Still follow authentic Taiwanese GSAT style, high-school Level 5-6 "
            "vocabulary, and plausible distractor logic."
        )

    example_blocks: list[str] = []
    for index, reference in enumerate(references, start=1):
        structure = reference.json_structure or "No JSON structure provided."
        example_blocks.append(
            "\n".join(
                [
                    f"Example {index} ({reference.year} {reference.exam_type})",
                    "Content:",
                    _clip_text(reference.content, 1800),
                    "JSON / Answer Structure:",
                    _clip_text(structure, 1000),
                ]
            )
        )

    return (
        "Few-Shot Examples from real Taiwanese GSAT past papers:\n\n"
        f"{chr(10).join(example_blocks)}\n\n"
        "Analyze the exact difficulty, vocabulary level (Taiwan High School Level 5-6), "
        "and distractor logic of these provided real exam examples. Generate a BRAND NEW "
        f"{exam_type} item that flawlessly mimics this exact style and complexity. "
        "Do not copy sentences, questions, or options from the examples."
    )


def extract_ollama_performance_metrics(
    ollama_response: dict[str, Any],
) -> PerformanceMetrics:
    eval_duration_ns = _safe_int(ollama_response.get("eval_duration"))
    eval_count = _safe_int(ollama_response.get("eval_count"))
    total_time_seconds = eval_duration_ns / 1_000_000_000

    tokens_per_second = 0.0
    if total_time_seconds > 0 and eval_count > 0:
        tokens_per_second = eval_count / total_time_seconds

    return PerformanceMetrics(
        total_time_seconds=round(total_time_seconds, 3),
        tokens_per_second=round(tokens_per_second, 1),
        total_tokens=eval_count,
        provider="ollama",
        model=OLLAMA_MODEL,
    )


def calculate_api_performance_metrics(
    elapsed_seconds: float,
    total_tokens: int,
    *,
    provider: str | None = None,
    model: str | None = None,
) -> PerformanceMetrics:
    tokens_per_second = 0.0
    if elapsed_seconds > 0 and total_tokens > 0:
        tokens_per_second = total_tokens / elapsed_seconds

    return PerformanceMetrics(
        total_time_seconds=round(elapsed_seconds, 3),
        tokens_per_second=round(tokens_per_second, 1),
        total_tokens=total_tokens,
        provider=provider,
        model=model,
    )


def normalize_app_mode(app_mode: str | None) -> str:
    return "focus" if str(app_mode or "").strip().lower() == "focus" else "engagement"


def app_mode_system_instruction(app_mode: str | None) -> str:
    mode = normalize_app_mode(app_mode)
    if mode == "focus":
        return (
            "App Mode: Focus. Use a strict, highly academic, concise GSAT examiner tone. "
            "Prioritize precision, test logic, and efficient explanations. Do not use emojis, "
            "jokes, slang, memes, or motivational filler."
        )
    return (
        "App Mode: Engagement. Be encouraging, clear, and slightly Gen-Z friendly while "
        "remaining accurate for Taiwanese GSAT preparation. Light humor and emojis are allowed "
        "when helpful, but never sacrifice correctness."
    )


def apply_app_mode_to_prompt(prompt: str, app_mode: str | None) -> str:
    return f"{app_mode_system_instruction(app_mode)}\n\n{prompt}"


def ai_runtime_signature() -> str:
    configured = configured_ai_providers()
    return "|".join(
        f"{provider['name']}:{provider['model']}" for provider in configured
    ) or "none"


def redact_student_pii(value: str) -> str:
    if not AI_REDACT_STUDENT_PII:
        return value
    redacted = re.sub(
        r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b",
        "[REDACTED_EMAIL]",
        value,
    )
    redacted = re.sub(r"\b09\d{2}[-\s]?\d{3}[-\s]?\d{3}\b", "[REDACTED_PHONE]", redacted)
    redacted = re.sub(r"\b[A-Z][12]\d{8}\b", "[REDACTED_ID]", redacted)
    redacted = re.sub(
        r"(?im)^(student\s+name|name|姓名)\s*[:：]\s*[^\n]+$",
        r"\1: [REDACTED_NAME]",
        redacted,
    )
    return redacted


def configured_ai_providers(*, vision: bool = False) -> list[dict[str, str]]:
    providers = {
        "gemini": {
            "name": "gemini",
            "base_url": GEMINI_BASE_URL,
            "api_key": GEMINI_API_KEY or "",
            "model": GEMINI_MODEL,
            "vision": "true",
        },
        "groq": {
            "name": "groq",
            "base_url": GROQ_BASE_URL,
            "api_key": GROQ_API_KEY or "",
            "model": GROQ_MODEL,
            "vision": "false",
        },
        "openai": {
            "name": "openai",
            "base_url": OPENAI_BASE_URL,
            "api_key": OPENAI_API_KEY or "",
            "model": CODEX_MODEL,
            "vision": "true",
        },
        "ollama": {
            "name": "ollama",
            "base_url": OLLAMA_BASE_URL,
            "api_key": "local",
            "model": OLLAMA_MODEL,
            "vision": "false",
        },
    }
    ordered: list[dict[str, str]] = []
    seen: set[str] = set()
    for raw_name in AI_PROVIDER_ORDER or ("ollama",):
        name = raw_name.strip().lower()
        provider = providers.get(name)
        if provider is None or name in seen:
            continue
        seen.add(name)
        if not provider["api_key"]:
            continue
        if vision and provider["vision"] != "true":
            continue
        ordered.append(provider)
    return ordered


async def call_ollama(prompt: str) -> tuple[str, PerformanceMetrics]:
    payload = {
        "model": OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
    }

    try:
        async with httpx.AsyncClient(timeout=OLLAMA_TIMEOUT_SECONDS) as client:
            response = await client.post(
                f"{OLLAMA_BASE_URL}/api/generate",
                json=payload,
            )
            response.raise_for_status()
    except httpx.TimeoutException as exc:
        raise HTTPException(
            status_code=504,
            detail="Ollama request timed out.",
        ) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Ollama request failed: {exc}",
        ) from exc

    data = response.json()
    generated_text = str(data.get("response", "")).strip()
    metrics = extract_ollama_performance_metrics(data)
    return generated_text, metrics


async def _post_openai_payload(
    payload: dict[str, Any],
    *,
    operation_name: str,
    base_url: str | None = None,
    api_key: str | None = None,
) -> tuple[dict[str, Any], float]:
    resolved_base_url = (base_url or OPENAI_BASE_URL).rstrip("/")
    resolved_api_key = api_key or OPENAI_API_KEY
    if not resolved_api_key:
        raise HTTPException(status_code=500, detail=f"{operation_name} API key is not configured.")
    headers = {
        "Authorization": f"Bearer {resolved_api_key}",
        "Content-Type": "application/json",
    }
    started_at = time.perf_counter()
    for attempt in range(OPENAI_MAX_RETRIES):
        try:
            async with httpx.AsyncClient(timeout=OPENAI_TIMEOUT_SECONDS) as client:
                response = await client.post(
                    f"{resolved_base_url}/chat/completions",
                    headers=headers,
                    json=payload,
                )
                response.raise_for_status()
        except httpx.TimeoutException as exc:
            if attempt + 1 >= OPENAI_MAX_RETRIES:
                raise HTTPException(
                    status_code=504,
                    detail=f"{operation_name} timed out after {OPENAI_MAX_RETRIES} attempts.",
                ) from exc
        except httpx.HTTPStatusError as exc:
            status = exc.response.status_code
            retryable = status == 429 or status >= 500
            if not retryable or attempt + 1 >= OPENAI_MAX_RETRIES:
                raise HTTPException(
                    status_code=502,
                    detail=f"{operation_name} failed with upstream status {status}.",
                ) from exc
        except httpx.HTTPError as exc:
            if attempt + 1 >= OPENAI_MAX_RETRIES:
                raise HTTPException(
                    status_code=502,
                    detail=f"{operation_name} failed after {OPENAI_MAX_RETRIES} attempts.",
                ) from exc
        else:
            try:
                data = response.json()
            except (ValueError, json.JSONDecodeError) as exc:
                raise HTTPException(
                    status_code=502,
                    detail=f"{operation_name} returned malformed JSON.",
                ) from exc
            if not isinstance(data, dict):
                raise HTTPException(
                    status_code=502,
                    detail=f"{operation_name} returned an invalid response object.",
                )
            return data, time.perf_counter() - started_at

        await asyncio.sleep(min(0.5 * (2**attempt), 2.0))

    raise HTTPException(status_code=502, detail=f"{operation_name} failed.")


def _openai_compatible_result(
    data: dict[str, Any],
    elapsed_seconds: float,
    *,
    provider: str,
    model: str,
) -> tuple[str, PerformanceMetrics]:
    choices = data.get("choices") or []
    message = choices[0].get("message", {}) if choices else {}
    generated_text = str(message.get("content", "")).strip()
    if not generated_text:
        raise HTTPException(status_code=502, detail=f"{provider} returned empty content.")
    usage = data.get("usage") or {}
    total_tokens = _safe_int(
        usage.get("total_tokens"),
        _safe_int(usage.get("completion_tokens")),
    )
    metrics = calculate_api_performance_metrics(
        elapsed_seconds,
        total_tokens,
        provider=provider,
        model=model,
    )
    return generated_text, metrics


async def _call_openai_compatible_text(
    provider: dict[str, str],
    prompt: str,
    app_mode: str | None,
) -> tuple[str, PerformanceMetrics]:
    payload = {
        "model": provider["model"],
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are an English GSAT exam diagnostic assistant for "
                    "Taiwanese high school students. "
                    f"{app_mode_system_instruction(app_mode)}"
                ),
            },
            {"role": "user", "content": redact_student_pii(prompt)},
        ],
        "temperature": 0.2,
    }
    data, elapsed_seconds = await _post_openai_payload(
        payload,
        operation_name=f"{provider['name']} API request",
        base_url=provider["base_url"],
        api_key=provider["api_key"],
    )
    return _openai_compatible_result(
        data,
        elapsed_seconds,
        provider=provider["name"],
        model=provider["model"],
    )


async def call_codex_api(
    prompt: str,
    app_mode: str | None = "engagement",
) -> tuple[str, PerformanceMetrics]:
    failures: list[str] = []
    for provider in configured_ai_providers():
        try:
            if provider["name"] == "ollama":
                text_value, metrics = await call_ollama(
                    apply_app_mode_to_prompt(redact_student_pii(prompt), app_mode)
                )
                metrics.provider = "ollama"
                metrics.model = OLLAMA_MODEL
                return text_value, metrics
            return await _call_openai_compatible_text(provider, prompt, app_mode)
        except HTTPException as exc:
            failures.append(f"{provider['name']}:{exc.status_code}")
    raise HTTPException(
        status_code=503,
        detail=(
            "All configured AI providers are unavailable. "
            f"Attempted: {', '.join(failures) or 'none'}."
        ),
    )


async def call_codex_vision_api(
    system_prompt: str,
    text_prompt: str,
    images: list[tuple[bytes, str]],
    app_mode: str | None = "engagement",
) -> tuple[str, PerformanceMetrics]:
    content: list[dict[str, Any]] = [
        {"type": "text", "text": redact_student_pii(text_prompt)}
    ]
    for image_bytes, content_type in images:
        if not content_type.startswith("image/"):
            raise HTTPException(status_code=415, detail="Prompt image must be an image file.")
        encoded_image = base64.b64encode(image_bytes).decode("utf-8")
        content.append(
            {
                "type": "image_url",
                "image_url": {
                    "url": f"data:{content_type};base64,{encoded_image}",
                    "detail": "high",
                },
            }
        )

    failures: list[str] = []
    for provider in configured_ai_providers(vision=True):
        payload = {
            "model": provider["model"],
            "messages": [
                {
                    "role": "system",
                    "content": (
                        f"{redact_student_pii(system_prompt)}\n\n"
                        f"{app_mode_system_instruction(app_mode)}"
                    ),
                },
                {"role": "user", "content": content},
            ],
            "temperature": 0.2,
        }
        try:
            data, elapsed_seconds = await _post_openai_payload(
                payload,
                operation_name=f"{provider['name']} Vision API request",
                base_url=provider["base_url"],
                api_key=provider["api_key"],
            )
            return _openai_compatible_result(
                data,
                elapsed_seconds,
                provider=provider["name"],
                model=provider["model"],
            )
        except HTTPException as exc:
            failures.append(f"{provider['name']}:{exc.status_code}")
    raise HTTPException(
        status_code=503,
        detail=(
            "No configured vision provider is available. "
            f"Attempted: {', '.join(failures) or 'none'}."
        ),
    )


async def call_preferred_text_ai(
    prompt: str,
    *,
    app_mode: str | None = "engagement",
) -> tuple[str, PerformanceMetrics]:
    return await call_codex_api(prompt, app_mode=app_mode)


async def generate_expansion_questions_for_mistake(
    db: Session,
    user_id: int,
    ledger_error_id: int,
    concept: str,
    original_question: str,
    wrong_answer: str,
    correct_answer: str,
    explanation: str,
    app_mode: str = "engagement",
    source_job_id: str | None = None,
) -> int:
    prompt = (
        "Create exactly 3 '舉一反三' practice questions for a Taiwanese GSAT "
        "English student. They must be similar in tested concept but completely "
        "new in wording, sentence context, and distractor logic. Return ONLY a "
        "JSON array. Each item must have: concept, question, options, "
        "correct_option_index, explanation.\n\n"
        f"Target concept: {concept}\n"
        f"Original question: {original_question}\n"
        f"Student wrong answer: {wrong_answer}\n"
        f"Correct answer: {correct_answer}\n"
        f"Teacher explanation: {explanation}"
    )

    generated_text, _metrics = await call_codex_api(prompt, app_mode=app_mode)
    raw_items = parse_json_array_from_text(generated_text)
    fallback_items = [
        {
            "concept": concept,
            "question": (
                "Choose the best answer that applies the same concept: "
                "The student kept practicing ____ the test became difficult."
            ),
            "options": ["although", "because of", "despite of", "instead"],
            "correct_option_index": 0,
            "explanation": (
                "Use a subordinating conjunction before a full clause. "
                "This checks the same logic as the original missed item."
            ),
        },
        {
            "concept": concept,
            "question": "Choose the sentence with the most natural GSAT-level English.",
            "options": [
                "She has improved because she reviews mistakes daily.",
                "She has improved because of she reviews mistakes daily.",
                "She improved because reviewing mistakes daily.",
                "She improves because to review mistakes daily.",
            ],
            "correct_option_index": 0,
            "explanation": (
                "The correct option connects cause and result with a complete clause."
            ),
        },
        {
            "concept": concept,
            "question": (
                "Which option best completes the sentence: Good learners notice "
                "____ they made mistakes."
            ),
            "options": ["why", "because of", "despite", "therefore"],
            "correct_option_index": 0,
            "explanation": (
                "Use a question word to introduce the content of what learners notice."
            ),
        },
    ]
    raw_items = [item for item in raw_items if isinstance(item, dict)]
    while len(raw_items) < 3:
        raw_items.append(fallback_items[len(raw_items)])

    tomorrow = datetime.utcnow().date() + timedelta(days=1)
    due_date = datetime.combine(tomorrow, datetime.min.time())
    inserted = 0
    for item in raw_items[:3]:
        if not isinstance(item, dict):
            continue
        options = safe_options(item.get("options"))
        correct_index = _safe_int(item.get("correct_option_index"))
        if correct_index < 0 or correct_index >= len(options):
            correct_index = 0
        question = _safe_string(item.get("question"))
        if not question:
            continue
        quiz = DailyExpansionQuiz(
            user_id=user_id,
            grammar_error_id=ledger_error_id,
            concept=normalize_concept(_safe_string(item.get("concept"), concept)),
            question=question,
            options_json=json.dumps(options, ensure_ascii=False),
            correct_option_index=correct_index,
            explanation=_safe_string(item.get("explanation"), explanation),
            due_date=due_date,
            source_job_id=source_job_id,
        )
        db.add(quiz)
        inserted += 1

    db.flush()
    return inserted


def background_job_to_response(job: BackgroundJob) -> BackgroundJobResponse:
    result: dict[str, Any] | None = None
    if job.result_json:
        try:
            parsed = json.loads(job.result_json)
            if isinstance(parsed, dict):
                result = parsed
        except json.JSONDecodeError:
            result = None
    return BackgroundJobResponse(
        id=job.id,
        job_type=job.job_type,
        status=job.status,
        attempts=job.attempts,
        result=result,
        error_message=job.error_message,
        created_at=job.created_at,
        updated_at=job.updated_at,
    )


async def run_expansion_job(job_id: str) -> None:
    with SessionLocal() as db:
        job = db.get(BackgroundJob, job_id)
        if job is None or job.status == "completed":
            return
        job.status = "running"
        job.attempts = int(job.attempts or 0) + 1
        job.error_message = None
        db.commit()

        try:
            payload = json.loads(job.payload_json)
            mistakes = payload.get("mistakes", []) if isinstance(payload, dict) else []
            app_mode = _safe_string(payload.get("app_mode"), "engagement") if isinstance(payload, dict) else "engagement"
            inserted = 0
            for mistake in mistakes:
                if not isinstance(mistake, dict):
                    continue
                ledger_error_id = _safe_int(mistake.get("ledger_error_id"))
                existing = db.scalar(
                    select(func.count(DailyExpansionQuiz.id)).where(
                        DailyExpansionQuiz.source_job_id == job_id,
                        DailyExpansionQuiz.grammar_error_id == ledger_error_id,
                    )
                ) or 0
                if existing >= 3:
                    inserted += int(existing)
                    continue
                inserted += await generate_expansion_questions_for_mistake(
                    db=db,
                    user_id=job.user_id,
                    ledger_error_id=ledger_error_id,
                    concept=_safe_string(mistake.get("concept"), "exam_mistake"),
                    original_question=_safe_string(mistake.get("original_question")),
                    wrong_answer=_safe_string(mistake.get("wrong_answer")),
                    correct_answer=_safe_string(mistake.get("correct_answer")),
                    explanation=_safe_string(mistake.get("explanation")),
                    app_mode=app_mode,
                    source_job_id=job_id,
                )
                db.commit()

            job.status = "completed"
            job.result_json = json.dumps(
                {"expansion_quiz_count": inserted, "due": "tomorrow"},
                ensure_ascii=False,
            )
            job.completed_at = datetime.utcnow()
            db.commit()
        except Exception as exc:
            db.rollback()
            failed_job = db.get(BackgroundJob, job_id)
            if failed_job is not None:
                failed_job.status = "failed"
                failed_job.error_message = _clip_text(str(exc), 1500)
                db.commit()


async def run_full_mock_exam_job(job_id: str) -> None:
    with SessionLocal() as db:
        job = db.get(BackgroundJob, job_id)
        if job is None or job.status == "completed":
            return
        job.status = "running"
        job.attempts = int(job.attempts or 0) + 1
        job.error_message = None
        db.commit()
        try:
            payload = json.loads(job.payload_json)
            request_model = FullMockExamRequest.model_validate(payload)
            user = db.get(User, job.user_id)
            if user is None:
                raise RuntimeError("Background-job user no longer exists.")
            response = await generate_full_mock_exam(
                request=request_model,
                db=db,
                current_user=user,
            )
            job.result_json = model_to_cache_json(response)
            job.status = "completed"
            job.completed_at = datetime.utcnow()
            db.commit()
        except Exception as exc:
            db.rollback()
            failed_job = db.get(BackgroundJob, job_id)
            if failed_job is None:
                return
            failed_job.status = "failed"
            failed_job.error_message = _clip_text(str(exc), 2000)
            db.commit()


def schedule_background_job(background_tasks: BackgroundTasks, job: BackgroundJob) -> None:
    if job.job_type == "ocr_expansion":
        background_tasks.add_task(run_expansion_job, job.id)
    elif job.job_type == "full_mock_exam":
        background_tasks.add_task(run_full_mock_exam_job, job.id)
    else:
        raise HTTPException(status_code=409, detail="Unsupported background job type.")


@app.get("/jobs/{job_id}", response_model=BackgroundJobResponse)
def get_background_job(
    job_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> BackgroundJobResponse:
    job = db.scalar(
        select(BackgroundJob).where(
            BackgroundJob.id == job_id,
            BackgroundJob.user_id == current_user.id,
        )
    )
    if job is None:
        raise HTTPException(status_code=404, detail="Background job not found.")
    return background_job_to_response(job)


@app.post("/jobs/{job_id}/retry", response_model=BackgroundJobResponse)
def retry_background_job(
    job_id: str,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> BackgroundJobResponse:
    job = db.scalar(
        select(BackgroundJob).where(
            BackgroundJob.id == job_id,
            BackgroundJob.user_id == current_user.id,
        )
    )
    if job is None:
        raise HTTPException(status_code=404, detail="Background job not found.")
    if job.status == "completed":
        return background_job_to_response(job)
    if int(job.attempts or 0) >= 3:
        raise HTTPException(status_code=409, detail="Background job retry limit reached.")
    job.status = "queued"
    job.error_message = None
    db.commit()
    db.refresh(job)
    schedule_background_job(background_tasks, job)
    return background_job_to_response(job)


def extract_text_from_image(image_bytes: bytes) -> str:
    try:
        image = Image.open(BytesIO(image_bytes))
        image = image.convert("RGB")
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Invalid image file.") from exc

    try:
        text = pytesseract.image_to_string(image, lang="eng")
    except pytesseract.TesseractNotFoundError as exc:
        raise HTTPException(
            status_code=500,
            detail=(
                "Tesseract OCR executable is not installed. Install it or set "
                "TESSERACT_CMD to the executable path."
            ),
        ) from exc
    except Exception as exc:
        raise HTTPException(status_code=500, detail="OCR processing failed.") from exc

    return " ".join(text.split())


_ALLOWED_IMAGE_MIME_TYPES = {
    "image/jpeg": "JPEG",
    "image/png": "PNG",
    "image/webp": "WEBP",
}


async def read_validated_image_upload(upload: Any, *, label: str) -> tuple[bytes, str]:
    content_type = str(getattr(upload, "content_type", "") or "").split(";", 1)[0].lower()
    expected_format = _ALLOWED_IMAGE_MIME_TYPES.get(content_type)
    if expected_format is None:
        raise HTTPException(
            status_code=415,
            detail=f"{label} must be a JPEG, PNG, or WebP image.",
        )
    image_bytes = await upload.read(settings.max_upload_bytes + 1)
    if not image_bytes:
        raise HTTPException(status_code=400, detail=f"{label} is empty.")
    if len(image_bytes) > settings.max_upload_bytes:
        raise HTTPException(
            status_code=413,
            detail=f"{label} exceeds the {settings.max_upload_bytes} byte limit.",
        )
    try:
        with Image.open(BytesIO(image_bytes)) as image:
            detected_format = (image.format or "").upper()
            image.verify()
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"{label} is not a valid image.") from exc
    if detected_format != expected_format:
        raise HTTPException(
            status_code=415,
            detail=f"{label} content does not match its declared MIME type.",
        )
    return image_bytes, content_type


@app.post("/vocab/add", response_model=VocabAddResponse)
def add_vocab(
    request: VocabAddRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> VocabAddResponse:
    user = current_user
    word = normalize_word(request.word)

    vocabulary = db.scalar(select(Vocabulary).where(Vocabulary.word == word))
    if vocabulary is None:
        vocabulary = Vocabulary(
            word=word,
            definition=request.definition,
            source_context=request.source_context,
        )
        db.add(vocabulary)
        db.flush()
    else:
        if request.definition and not vocabulary.definition:
            vocabulary.definition = request.definition
        if request.source_context:
            vocabulary.source_context = request.source_context

    progress = db.scalar(
        select(UserVocabProgress).where(
            UserVocabProgress.user_id == user.id,
            UserVocabProgress.vocab_id == vocabulary.id,
        )
    )
    if progress is None:
        progress = UserVocabProgress(
            user_id=user.id,
            vocab_id=vocabulary.id,
            interval=0,
            repetitions=0,
            ease_factor=2.5,
            next_review_date=datetime.utcnow(),
        )
        db.add(progress)

    db.commit()
    db.refresh(vocabulary)
    db.refresh(progress)

    return VocabAddResponse(
        vocab_id=vocabulary.id,
        word=vocabulary.word,
        user_id=user.id,
        interval=progress.interval,
        repetitions=progress.repetitions,
        ease_factor=progress.ease_factor,
        next_review_date=progress.next_review_date,
    )


def _week_start(value: date) -> date:
    return value - timedelta(days=value.weekday())


def _local_today(preference: UserLearningPreference | None = None) -> date:
    timezone_name = preference.timezone if preference is not None else "Asia/Taipei"
    try:
        return datetime.now(ZoneInfo(timezone_name or "Asia/Taipei")).date()
    except ZoneInfoNotFoundError:
        return datetime.now(timezone(timedelta(hours=8))).date()


def get_or_create_learning_preference(db: Session, user_id: int) -> UserLearningPreference:
    preference = db.scalar(
        select(UserLearningPreference).where(UserLearningPreference.user_id == user_id)
    )
    if preference is None:
        preference = UserLearningPreference(user_id=user_id)
        db.add(preference)
        db.flush()
    return preference


def get_or_create_reward_state(
    db: Session,
    user_id: int,
    *,
    preference: UserLearningPreference | None = None,
) -> LearningRewardState:
    state = db.scalar(
        select(LearningRewardState).where(LearningRewardState.user_id == user_id)
    )
    if state is None:
        state = LearningRewardState(user_id=user_id)
        db.add(state)
        db.flush()
    preference = preference or get_or_create_learning_preference(db, user_id)
    current_week = _week_start(_local_today(preference))
    if state.last_shield_refill_week is None or state.last_shield_refill_week < current_week:
        state.streak_shields = max(1, int(state.streak_shields or 0))
        state.last_shield_refill_week = current_week
    return state


def learning_preferences_response(
    preference: UserLearningPreference,
) -> LearningPreferencesResponse:
    return LearningPreferencesResponse(
        weekday_minutes=int(preference.weekday_minutes or 10),
        weekend_minutes=int(preference.weekend_minutes or 20),
        preferred_session_minutes=int(preference.preferred_session_minutes or 10),
        rescue_session_minutes=int(preference.rescue_session_minutes or 3),
        maximum_session_minutes=int(preference.maximum_session_minutes or 60),
        weekly_goal_days=int(preference.weekly_goal_days or 5),
        timezone=preference.timezone or "Asia/Taipei",
        gentle_streak_enabled=bool(preference.gentle_streak_enabled),
        paper_pack_enabled=bool(preference.paper_pack_enabled),
    )


def build_reward_summary(
    db: Session,
    user: User,
    *,
    preference: UserLearningPreference | None = None,
    state: LearningRewardState | None = None,
) -> RewardSummary:
    preference = preference or get_or_create_learning_preference(db, user.id)
    state = state or get_or_create_reward_state(
        db,
        user.id,
        preference=preference,
    )
    today = _local_today(preference)
    start = _week_start(today)
    weekly_active_days = db.scalar(
        select(func.count(func.distinct(LearningProgressEvent.event_date))).where(
            LearningProgressEvent.user_id == user.id,
            LearningProgressEvent.event_date >= start,
            LearningProgressEvent.event_date <= today,
        )
    ) or 0
    total_points = max(0, int(state.total_points or 0))
    level = max(1, int(state.level or 1))
    points_in_level = total_points % 100
    weekly_goal = max(1, min(7, int(preference.weekly_goal_days or 5)))
    if total_points == 0:
        headline = "先完成一個一分鐘暖身，你今天就已經開始進步。"
    elif int(weekly_active_days) >= weekly_goal:
        headline = f"本週目標已達成，你累積了 {int(weekly_active_days)} 個有效學習日。"
    elif state.comeback_count:
        headline = "回來繼續比完美更重要，你的進度沒有白費。"
    else:
        headline = f"你已累積 {total_points} 成長點，每一次訂正都算進步。"
    return RewardSummary(
        total_points=total_points,
        level=level,
        level_progress=round(points_in_level / 100, 3),
        points_to_next_level=100 - points_in_level if points_in_level else 100,
        weekly_active_days=int(weekly_active_days),
        weekly_goal_days=weekly_goal,
        weekly_goal_progress=round(min(1.0, int(weekly_active_days) / weekly_goal), 3),
        comeback_count=int(state.comeback_count or 0),
        streak_shields=int(state.streak_shields or 0),
        current_streak=int(user.current_streak or 0),
        headline=headline,
    )


def record_learning_event(
    db: Session,
    *,
    user: User,
    source_key: str,
    event_type: str,
    points: int,
    message: str,
    skill: str | None = None,
    outcome: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> RewardFeedback:
    preference = get_or_create_learning_preference(db, user.id)
    state = get_or_create_reward_state(db, user.id, preference=preference)
    existing = db.scalar(
        select(LearningProgressEvent).where(LearningProgressEvent.source_key == source_key)
    )
    if existing is not None:
        return RewardFeedback(
            awarded=False,
            points=0,
            message="這次進度已經記錄，不會重複計分。",
            total_points=int(state.total_points or 0),
            level=int(state.level or 1),
            level_up=False,
        )

    today = _local_today(preference)
    comeback = False
    if state.last_active_date is None:
        user.current_streak = max(1, int(user.current_streak or 1))
    elif state.last_active_date == today:
        pass
    elif state.last_active_date == today - timedelta(days=1):
        user.current_streak = max(1, int(user.current_streak or 0) + 1)
    elif (
        bool(preference.gentle_streak_enabled)
        and state.last_active_date == today - timedelta(days=2)
        and int(state.streak_shields or 0) > 0
    ):
        state.streak_shields = int(state.streak_shields or 0) - 1
        user.current_streak = max(1, int(user.current_streak or 1))
        state.comeback_count = int(state.comeback_count or 0) + 1
        comeback = True
    else:
        if state.last_active_date < today - timedelta(days=1):
            state.comeback_count = int(state.comeback_count or 0) + 1
            comeback = True
        user.current_streak = 1
    state.last_active_date = today

    previous_level = max(1, int(state.level or 1))
    awarded_points = max(1, min(50, int(points)))
    state.total_points = int(state.total_points or 0) + awarded_points
    state.level = int(state.total_points // 100) + 1
    final_message = (
        "你願意回來就是一次勝利。" if comeback else message
    )
    event = LearningProgressEvent(
        user_id=user.id,
        source_key=source_key,
        event_type=event_type,
        skill=skill,
        outcome=outcome,
        points=awarded_points,
        message=final_message,
        metadata_json=json.dumps(metadata or {}, ensure_ascii=False),
        event_date=today,
    )
    db.add(event)
    db.flush()
    return RewardFeedback(
        awarded=True,
        points=awarded_points,
        message=final_message,
        total_points=int(state.total_points),
        level=int(state.level),
        level_up=int(state.level) > previous_level,
    )


def _session_mode(minutes: int) -> str:
    if minutes <= 3:
        return "rescue"
    if minutes <= 10:
        return "quick"
    if minutes <= 20:
        return "sprint"
    return "deep"


def _difficulty_for_skill(value: float) -> tuple[str, float]:
    if value < 0.35:
        return "foundation", 0.90
    if value < 0.65:
        return "developing", 0.82
    return "challenge", 0.72


def build_minute_budget_task_specs(
    *,
    available_minutes: int,
    focus_skill: str,
    skills: dict[str, float],
    days_remaining: int,
) -> list[dict[str, Any]]:
    budget = max(3, min(60, int(available_minutes)))
    difficulty, success_target = _difficulty_for_skill(skills[focus_skill])
    topics = {
        "vocab": "先認得最常考的核心字義",
        "grammar": "從最容易得分的句型判斷開始",
        "reading": "先找轉折詞與主旨句",
        "writing": "先寫出一個正確、清楚的主題句",
    }
    specs: list[dict[str, Any]] = [
        {
            "task_key": "micro_win",
            "task_type": "micro_win",
            "count": 3,
            "topic": "一分鐘必勝暖身",
            "minutes": 1,
            "priority": "high",
            "difficulty": "foundation",
            "success_target": 0.95,
            "reward_points": 8,
        }
    ]
    candidates: list[dict[str, Any]] = []

    focus_minutes = {
        "vocab": 3,
        "grammar": 3,
        "reading": 5,
        "writing": 8,
    }[focus_skill]
    focus_type = {
        "vocab": "vocab",
        "grammar": "grammar",
        "reading": "reading_practice",
        "writing": "writing_sprint",
    }[focus_skill]
    candidates.append(
        {
            "task_key": f"focus_{focus_skill}",
            "task_type": focus_type,
            "count": max(3, focus_minutes * 2) if focus_skill != "writing" else None,
            "topic": topics[focus_skill],
            "minutes": focus_minutes,
            "priority": "high",
            "difficulty": difficulty,
            "success_target": success_target,
            "reward_points": 12,
        }
    )
    candidates.extend(
        [
            {
                "task_key": "vocab",
                "task_type": "vocab",
                "count": 8,
                "topic": "高頻單字快速回想",
                "minutes": 3,
                "priority": "core",
                "difficulty": "foundation" if skills["vocab"] < 0.5 else "developing",
                "success_target": 0.88,
                "reward_points": 10,
            },
            {
                "task_key": "grammar",
                "task_type": "grammar",
                "count": 3,
                "topic": "一題一觀念，不一次塞滿規則",
                "minutes": 3,
                "priority": "core",
                "difficulty": "foundation" if skills["grammar"] < 0.5 else "developing",
                "success_target": 0.85,
                "reward_points": 10,
            },
            {
                "task_key": "reading_practice",
                "task_type": "reading_practice",
                "count": 1,
                "topic": "短篇主旨與轉折定位",
                "minutes": 5,
                "priority": "core",
                "difficulty": difficulty,
                "success_target": 0.80,
                "reward_points": 14,
            },
            {
                "task_key": "mixed_questions",
                "task_type": "mixed_questions",
                "count": 1,
                "topic": "學測混合題小組合",
                "minutes": 6,
                "priority": "core",
                "difficulty": difficulty,
                "success_target": 0.76,
                "reward_points": 16,
            },
            {
                "task_key": "writing_sprint",
                "task_type": "writing_sprint",
                "topic": "只完成一個可得分段落",
                "minutes": 8,
                "priority": "core",
                "difficulty": difficulty,
                "success_target": 0.75,
                "reward_points": 18,
            },
        ]
    )
    if days_remaining <= 7:
        candidates.insert(
            1,
            {
                "task_key": "final_review",
                "task_type": "final_review",
                "topic": "只看尚未掌握的錯題與單字",
                "minutes": 5,
                "priority": "high",
                "difficulty": "developing",
                "success_target": 0.82,
                "reward_points": 15,
            },
        )

    used = 1
    seen_types = {"micro_win"}
    for candidate in candidates:
        candidate_type = str(candidate["task_type"])
        if candidate_type in seen_types:
            continue
        minutes = int(candidate["minutes"])
        if used + minutes <= budget:
            specs.append(candidate)
            used += minutes
            seen_types.add(candidate_type)

    remaining = budget - used
    if remaining >= 2:
        specs.append(
            {
                "task_key": "confidence_recap",
                "task_type": "confidence_recap",
                "count": 1,
                "topic": "寫下今天確定學會的一件事",
                "minutes": min(3, remaining),
                "priority": "core",
                "difficulty": "foundation",
                "success_target": 1.0,
                "reward_points": 6,
            }
        )
    if len(specs) == 1:
        specs.append(
            {
                "task_key": "rescue_recall",
                "task_type": "vocab",
                "count": 4,
                "topic": "救援模式：只回想四個看過的單字",
                "minutes": budget - 1,
                "priority": "core",
                "difficulty": "foundation",
                "success_target": 0.90,
                "reward_points": 7,
            }
        )
    return specs


def daily_task_response(
    task: DailyMissionTask,
    *,
    reward: RewardFeedback | None = None,
) -> DailyScheduleTask:
    return DailyScheduleTask(
        id=task.id,
        task_key=task.task_key,
        type=task.task_type,
        count=task.count,
        topic=task.topic,
        minutes=task.minutes,
        priority=task.priority,
        difficulty=task.difficulty or "foundation",
        success_target=float(task.success_target or 0.85),
        reward_points=int(task.reward_points or 10),
        status=task.status,
        reward=reward,
    )


@app.get("/user/learning-preferences", response_model=LearningPreferencesResponse)
def get_learning_preferences(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> LearningPreferencesResponse:
    preference = get_or_create_learning_preference(db, current_user.id)
    db.commit()
    return learning_preferences_response(preference)


@app.put("/user/learning-preferences", response_model=LearningPreferencesResponse)
def update_learning_preferences(
    request: LearningPreferencesUpdateRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> LearningPreferencesResponse:
    preference = get_or_create_learning_preference(db, current_user.id)
    for field_name, value in request.model_dump(exclude_none=True).items():
        setattr(preference, field_name, value.strip() if isinstance(value, str) else value)
    if int(preference.rescue_session_minutes) > int(preference.preferred_session_minutes):
        raise HTTPException(status_code=422, detail="Rescue session cannot exceed preferred session.")
    if int(preference.preferred_session_minutes) > int(preference.maximum_session_minutes):
        raise HTTPException(status_code=422, detail="Preferred session cannot exceed maximum session.")
    db.commit()
    db.refresh(preference)
    return learning_preferences_response(preference)


@app.get("/user/reward-summary", response_model=RewardSummary)
def get_reward_summary(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> RewardSummary:
    user = db.get(User, current_user.id)
    if user is None:
        raise HTTPException(status_code=401, detail="Token user no longer exists.")
    summary = build_reward_summary(db, user)
    db.commit()
    return summary


@app.post("/user/learning-events", response_model=LearningEventResponse)
def add_learning_event(
    request: LearningEventRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> LearningEventResponse:
    user = db.get(User, current_user.id)
    if user is None:
        raise HTTPException(status_code=401, detail="Token user no longer exists.")
    event_type = re.sub(r"[^a-z0-9_]+", "_", request.event_type.strip().lower())
    outcome = re.sub(r"[^a-z0-9_]+", "_", (request.outcome or "").strip().lower())
    points_map = {
        "grammar_correct": 12,
        "grammar_retry_mastered": 20,
        "reading_completed": 12,
        "writing_submitted": 18,
        "effort_reviewed": 6,
        "translation_completed": 12,
        "paper_day_completed": 14,
    }
    points = points_map.get(event_type, 5)
    message = (
        "你把原本不會的題目救回來了，這種進步最有價值。"
        if event_type == "grammar_retry_mastered"
        else "這一步已經記進你的成長曲線。"
    )
    reward = record_learning_event(
        db,
        user=user,
        source_key=f"user:{user.id}:event:{request.source_key}",
        event_type=event_type,
        skill=request.skill,
        outcome=outcome or None,
        points=points,
        message=message,
        metadata=request.metadata,
    )
    db.commit()
    return LearningEventResponse(reward=reward, summary=build_reward_summary(db, user))


@app.get("/user/stats", response_model=UserStatsResponse)
def get_user_stats(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserStatsResponse:
    return build_user_stats(db, current_user)


@app.get("/user/daily-schedule", response_model=DailyScheduleResponse)
def get_user_daily_schedule(
    available_minutes: int | None = None,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DailyScheduleResponse:
    user = db.get(User, current_user.id)
    if user is None:
        raise HTTPException(status_code=401, detail="Token user no longer exists.")
    if available_minutes is not None and not 3 <= available_minutes <= 60:
        raise HTTPException(status_code=422, detail="Available minutes must be between 3 and 60.")
    return compose_daily_schedule(
        db,
        user,
        available_minutes=available_minutes,
        force_replan=available_minutes is not None,
    )


def compose_daily_schedule(
    db: Session,
    user: User,
    *,
    available_minutes: int | None = None,
    force_replan: bool = False,
) -> DailyScheduleResponse:
    preference = get_or_create_learning_preference(db, user.id)

    now = datetime.utcnow()
    local_today = _local_today(preference)
    if user.target_exam_date is None or user.target_exam_date <= now:
        user.target_exam_date = now + timedelta(days=90)

    days_remaining = max(0, (user.target_exam_date.date() - local_today).days)
    original_window = max(1, (user.target_exam_date - user.created_at).days)
    elapsed_window = max(0, (now - user.created_at).days)
    upward_curve = min(1.0, max(0.0, elapsed_window / original_window))

    skills = {
        "vocab": float(user.skill_vocabulary or 0.0),
        "grammar": float(user.skill_grammar or 0.0),
        "reading": float(user.skill_reading or 0.0),
        "writing": float(user.skill_writing or 0.0),
    }
    focus_skill = min(skills, key=skills.get)
    default_budget = (
        int(preference.weekend_minutes or 20)
        if local_today.weekday() >= 5
        else int(preference.weekday_minutes or 10)
    )
    budget = max(3, min(60, int(available_minutes or default_budget)))

    mission_date = local_today
    persisted_tasks = list(
        db.scalars(
            select(DailyMissionTask)
            .where(
                DailyMissionTask.user_id == user.id,
                DailyMissionTask.mission_date == mission_date,
            )
            .order_by(DailyMissionTask.id.asc())
        )
    )
    needs_new_plan = not persisted_tasks or not any(
        task.task_key == "micro_win" for task in persisted_tasks
    )
    if force_replan or needs_new_plan:
        completed_tasks = [task for task in persisted_tasks if task.status == "completed"]
        for task in persisted_tasks:
            if task.status != "completed":
                db.delete(task)
        db.flush()
        completed_keys = {task.task_key for task in completed_tasks}
        completed_minutes = sum(max(0, int(task.minutes or 0)) for task in completed_tasks)
        remaining_budget = max(0, budget - completed_minutes)
        task_specs = (
            build_minute_budget_task_specs(
                available_minutes=remaining_budget,
                focus_skill=focus_skill,
                skills=skills,
                days_remaining=days_remaining,
            )
            if remaining_budget >= 3
            else []
        )
        for spec in task_specs:
            if spec["task_key"] in completed_keys:
                continue
            db.add(
                DailyMissionTask(
                    user_id=user.id,
                    mission_date=mission_date,
                    status="pending",
                    **spec,
                )
            )
        db.commit()
        persisted_tasks = list(
            db.scalars(
                select(DailyMissionTask)
                .where(
                    DailyMissionTask.user_id == user.id,
                    DailyMissionTask.mission_date == mission_date,
                )
                .order_by(DailyMissionTask.id.asc())
            )
        )

    planned_minutes = sum(max(0, int(task.minutes or 0)) for task in persisted_tasks)
    mode = _session_mode(budget)
    encouragement = {
        "rescue": "三分鐘不是偷懶，是讓學習不中斷。完成後今天就可以停。",
        "quick": "十分鐘足以完成一次有效複習，不需要把自己耗盡。",
        "sprint": "今天只處理最有機會加分的弱點，完成後安心收工。",
        "deep": "你今天有較完整的時間，系統仍會把任務拆成短段落。",
    }[mode]
    reward_summary = build_reward_summary(db, user, preference=preference)
    db.commit()

    return DailyScheduleResponse(
        target_exam_date=user.target_exam_date,
        days_remaining=days_remaining,
        upward_curve=round(upward_curve, 3),
        focus_skill=focus_skill,
        available_minutes=budget,
        planned_minutes=planned_minutes,
        session_mode=mode,
        encouragement=encouragement,
        reward_summary=reward_summary,
        tasks=[daily_task_response(task) for task in persisted_tasks],
    )


@app.post("/user/daily-schedule/replan", response_model=DailyScheduleResponse)
def replan_user_daily_schedule(
    request: DailyScheduleReplanRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DailyScheduleResponse:
    user = db.get(User, current_user.id)
    if user is None:
        raise HTTPException(status_code=401, detail="Token user no longer exists.")
    return compose_daily_schedule(
        db,
        user,
        available_minutes=request.available_minutes,
        force_replan=True,
    )


@app.patch("/user/daily-schedule/tasks/{task_id}", response_model=DailyScheduleTask)
def update_daily_schedule_task(
    task_id: int,
    request: DailyScheduleTaskUpdateRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DailyScheduleTask:
    task = db.scalar(
        select(DailyMissionTask).where(
            DailyMissionTask.id == task_id,
            DailyMissionTask.user_id == current_user.id,
        )
    )
    if task is None:
        raise HTTPException(status_code=404, detail="Daily mission task not found.")
    was_completed = task.status == "completed"
    task.status = "completed" if request.completed else "pending"
    task.completed_at = datetime.utcnow() if request.completed else None
    user = db.get(User, current_user.id)
    reward: RewardFeedback | None = None
    if request.completed and not was_completed and user is not None:
        skill_field = {
            "micro_win": "skill_vocabulary",
            "vocab": "skill_vocabulary",
            "grammar": "skill_grammar",
            "mixed_questions": "skill_reading",
            "reading_practice": "skill_reading",
            "writing_sprint": "skill_writing",
        }.get(task.task_type)
        if skill_field:
            current_value = float(getattr(user, skill_field) or 0.0)
            setattr(user, skill_field, round(min(1.0, current_value + 0.01), 2))
        reward = record_learning_event(
            db,
            user=user,
            source_key=f"user:{user.id}:mission:{task.id}:completed",
            event_type="mission_completed",
            skill=task.task_type,
            outcome="completed",
            points=int(task.reward_points or 10),
            message=(
                "第一個小任務完成了，今天的進步已經成立。"
                if task.task_type == "micro_win"
                else "你完成了一個可量化的小進步。"
            ),
            metadata={"task_key": task.task_key, "minutes": task.minutes},
        )
    db.commit()
    db.refresh(task)
    if request.completed and was_completed and user is not None:
        reward = record_learning_event(
            db,
            user=user,
            source_key=f"user:{user.id}:mission:{task.id}:completed",
            event_type="mission_completed",
            skill=task.task_type,
            outcome="completed",
            points=int(task.reward_points or 10),
            message="你完成了一個可量化的小進步。",
        )
    return daily_task_response(task, reward=reward)


@app.patch("/user/target-exam-date", response_model=DailyScheduleResponse)
def set_target_exam_date(
    request: TargetExamDateRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DailyScheduleResponse:
    now = datetime.utcnow()
    requested = request.target_exam_date.replace(tzinfo=None)
    if requested.date() <= now.date():
        raise HTTPException(status_code=422, detail="Target exam date must be in the future.")
    if requested > now + timedelta(days=5 * 366):
        raise HTTPException(status_code=422, detail="Target exam date is too far in the future.")
    user = db.get(User, current_user.id)
    if user is None:
        raise HTTPException(status_code=401, detail="Token user no longer exists.")
    user.target_exam_date = requested
    db.commit()
    return get_user_daily_schedule(db=db, current_user=user)


@app.post("/user/weekly-report", response_model=WeeklyReportResponse)
async def generate_weekly_report(
    request: WeeklyReportRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> WeeklyReportResponse:
    since = datetime.utcnow() - timedelta(days=7)
    vocab_reviews = db.scalar(
        select(func.count(UserVocabProgress.id)).where(
            UserVocabProgress.user_id == current_user.id,
            UserVocabProgress.last_reviewed_at >= since,
        )
    ) or 0
    new_errors = db.scalar(
        select(func.count(GrammarErrorLedger.id)).where(
            GrammarErrorLedger.user_id == current_user.id,
            GrammarErrorLedger.created_at >= since,
        )
    ) or 0
    mastered_errors = db.scalar(
        select(func.count(GrammarErrorLedger.id)).where(
            GrammarErrorLedger.user_id == current_user.id,
            GrammarErrorLedger.is_mastered.is_(True),
            GrammarErrorLedger.updated_at >= since,
        )
    ) or 0
    mission_tasks_total = db.scalar(
        select(func.count(DailyMissionTask.id)).where(
            DailyMissionTask.user_id == current_user.id,
            DailyMissionTask.mission_date >= since.date(),
        )
    ) or 0
    mission_tasks_completed = db.scalar(
        select(func.count(DailyMissionTask.id)).where(
            DailyMissionTask.user_id == current_user.id,
            DailyMissionTask.mission_date >= since.date(),
            DailyMissionTask.status == "completed",
        )
    ) or 0
    concept_rows = db.execute(
        select(
            GrammarErrorLedger.error_type,
            func.count(GrammarErrorLedger.id).label("error_count"),
        )
        .where(
            GrammarErrorLedger.user_id == current_user.id,
            GrammarErrorLedger.updated_at >= since,
        )
        .group_by(GrammarErrorLedger.error_type)
        .order_by(func.count(GrammarErrorLedger.id).desc())
        .limit(5)
    ).all()
    top_concepts = [str(row[0]) for row in concept_rows if row[0]]
    persona = "Spartan" if request.persona.strip().lower() == "spartan" else "Encouraging"
    persona_instruction = (
        "Persona: Spartan. Be strict, blunt, and mildly roasting, but never insulting. "
        "Use no fluff. Make the student feel accountable."
        if persona == "Spartan"
        else "Persona: Encouraging. Be warm, motivating, and practical. Celebrate effort while staying honest."
    )
    prompt = (
        "Write a personalized weekly GSAT English study report in about 150 English words. "
        "Summarize what happened, identify the main trend, and give 3 concrete actions for next week. "
        "Reference the student's data directly. Do not invent exact scores beyond the data provided.\n\n"
        f"{persona_instruction}\n"
        f"Vocab cards reviewed in last 7 days: {vocab_reviews}\n"
        f"New grammar/error ledger entries: {new_errors}\n"
        f"Mastered error ledger entries: {mastered_errors}\n"
        f"Daily mission tasks completed: {mission_tasks_completed}/{mission_tasks_total}\n"
        f"Top recurring concepts: {', '.join(top_concepts) or 'not enough data yet'}\n"
        f"Radar skills: vocab={current_user.skill_vocabulary}, grammar={current_user.skill_grammar}, "
        f"reading={current_user.skill_reading}, writing={current_user.skill_writing}"
    )
    report, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    return WeeklyReportResponse(
        persona=persona,
        report=_clip_text(report, 1600),
        vocab_reviews=int(vocab_reviews),
        new_errors=int(new_errors),
        mastered_errors=int(mastered_errors),
        mission_tasks_completed=int(mission_tasks_completed),
        mission_tasks_total=int(mission_tasks_total),
        top_error_concepts=top_concepts,
        performance_metrics=metrics,
    )


def build_user_stats(db: Session, current_user: User) -> UserStatsResponse:
    total_words_mastered = db.scalar(
        select(func.count(UserVocabProgress.id)).where(
            UserVocabProgress.user_id == current_user.id,
            UserVocabProgress.repetitions >= 3,
        )
    ) or 0

    if current_user.grammar_score_count:
        average_grammar_score = (
            (current_user.grammar_score_total or 0.0)
            / current_user.grammar_score_count
        )
    else:
        total_errors = db.scalar(
            select(func.count(GrammarErrorLedger.id)).where(
                GrammarErrorLedger.user_id == current_user.id,
            )
        ) or 0
        mastered_errors = db.scalar(
            select(func.count(GrammarErrorLedger.id)).where(
                GrammarErrorLedger.user_id == current_user.id,
                GrammarErrorLedger.is_mastered.is_(True),
            )
        ) or 0
        average_grammar_score = (
            (mastered_errors / total_errors) * 5 if total_errors else 0.0
        )

    return UserStatsResponse(
        total_words_mastered=int(total_words_mastered),
        average_grammar_score=round(average_grammar_score, 1),
        total_essays_written=int(current_user.essays_written or 0),
        vocabulary_skill=round(float(current_user.skill_vocabulary or 0.0), 2),
        grammar_skill=round(float(current_user.skill_grammar or 0.0), 2),
        reading_skill=round(float(current_user.skill_reading or 0.0), 2),
        writing_skill=round(float(current_user.skill_writing or 0.0), 2),
    )


def _study_pack_response(pack: WeeklyStudyPack) -> WeeklyStudyPackResponse:
    try:
        completed_days = sorted(
            {
                int(day)
                for day in json.loads(pack.completed_days_json or "[]")
                if 1 <= int(day) <= 5
            }
        )
    except (TypeError, ValueError, json.JSONDecodeError):
        completed_days = []
    try:
        payload = json.loads(pack.payload_json)
        day_count = len(payload.get("days", [])) if isinstance(payload, dict) else 5
    except (TypeError, ValueError, json.JSONDecodeError):
        day_count = 5
    return WeeklyStudyPackResponse(
        id=pack.id,
        week_start=pack.week_start,
        pack_code=pack.pack_code,
        daily_minutes=pack.daily_minutes,
        status=pack.status,
        completed_days=completed_days,
        day_count=max(1, day_count),
        generated_at=pack.generated_at,
        pdf_url=f"/user/weekly-study-pack/{pack.id}/pdf",
    )


def _weekly_pack_code(db: Session) -> str:
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    for _ in range(20):
        candidate = "".join(secrets.choice(alphabet) for _ in range(8))
        if db.scalar(
            select(WeeklyStudyPack.id).where(WeeklyStudyPack.pack_code == candidate)
        ) is None:
            return candidate
    raise HTTPException(status_code=500, detail="Unable to allocate a study pack code.")


def _build_weekly_study_pack_payload(
    db: Session,
    user: User,
    *,
    week_start: date,
    daily_minutes: int,
) -> dict[str, Any]:
    vocab_rows = db.execute(
        select(Vocabulary, UserVocabProgress)
        .join(UserVocabProgress, UserVocabProgress.vocab_id == Vocabulary.id)
        .where(UserVocabProgress.user_id == user.id)
        .order_by(
            UserVocabProgress.ease_factor.asc(),
            UserVocabProgress.repetitions.asc(),
            UserVocabProgress.next_review_date.asc(),
        )
        .limit(30)
    ).all()
    vocabulary_items = [
        {
            "word": vocab.word,
            "meaning": vocab.definition or "請寫下你記得的中文意思",
            "example": vocab.source_context or f"Write one sentence using {vocab.word}.",
        }
        for vocab, _progress in vocab_rows
    ]
    if not vocabulary_items:
        vocabulary_items = [
            {"word": word, "meaning": meaning, "example": example}
            for word, meaning, example in (
                INITIAL_EASY_GSAT_WORDS + INITIAL_HARD_GSAT_WORDS
            )
        ]

    grammar_rows = list(
        db.scalars(
            select(GrammarErrorLedger)
            .where(
                GrammarErrorLedger.user_id == user.id,
                GrammarErrorLedger.is_mastered.is_(False),
            )
            .order_by(
                GrammarErrorLedger.occurrence_count.desc(),
                GrammarErrorLedger.updated_at.desc(),
            )
            .limit(10)
        )
    )
    grammar_items = [
        {
            "concept": _titleize_concept(item.error_type),
            "question": item.original_sentence,
            "wrong_answer": item.user_answer or "",
            "correct_answer": item.corrected_sentence or "Check the rule and rewrite the sentence.",
            "explanation": item.explanation or "Identify the grammar signal and explain the correction.",
        }
        for item in grammar_rows
    ]
    if not grammar_items:
        grammar_items = [
            {
                "concept": "Subject-Verb Agreement",
                "question": "Each of the students have a different study plan.",
                "wrong_answer": "have",
                "correct_answer": "Each of the students has a different study plan.",
                "explanation": "Each is singular, so the verb must be has.",
            },
            {
                "concept": "Inversion",
                "question": "I had never seen such a useful review sheet.",
                "wrong_answer": "",
                "correct_answer": "Never had I seen such a useful review sheet.",
                "explanation": "A negative adverb at the beginning triggers auxiliary-subject inversion.",
            },
            {
                "concept": "Participle Clause",
                "question": "Because she felt tired, she took a short break.",
                "wrong_answer": "",
                "correct_answer": "Feeling tired, she took a short break.",
                "explanation": "The subjects are the same, so the adverb clause can become a participle clause.",
            },
        ]

    vocab_count = 2 if daily_minutes <= 5 else 4 if daily_minutes <= 10 else 6 if daily_minutes <= 20 else 8
    days: list[dict[str, Any]] = []
    for day_index in range(5):
        selected_vocab = [
            vocabulary_items[(day_index * vocab_count + offset) % len(vocabulary_items)]
            for offset in range(vocab_count)
        ]
        grammar = grammar_items[day_index % len(grammar_items)]
        words_in_context = ", ".join(item["word"] for item in selected_vocab[:4])
        reading_text = (
            "Small study sessions can produce meaningful progress. A learner who reviews "
            "a few difficult words, checks one grammar pattern, and recalls the ideas without "
            "looking at the answers is training long-term memory. The goal is not to study "
            "until exhaustion. It is to return tomorrow with enough energy to continue. "
            f"Today's focus words are {words_in_context}."
        )
        day_number = day_index + 1
        days.append(
            {
                "day": day_number,
                "date": (week_start + timedelta(days=day_index)).isoformat(),
                "title": f"Day {day_number} - Small Win Sprint",
                "minutes": daily_minutes,
                "vocabulary": selected_vocab,
                "grammar": grammar,
                "reading": {
                    "text": reading_text,
                    "questions": [
                        "In one English sentence, state the main idea.",
                        f"Circle every occurrence of one focus word and explain {selected_vocab[0]['word']} in Chinese.",
                    ],
                    "answers": [
                        "Short, repeatable study sessions build sustainable progress.",
                        selected_vocab[0]["meaning"],
                    ],
                },
                "reflection": "今天我確實記住的一件事：____________________________",
            }
        )

    return {
        "title": "GSAT_Max 五日紙本衝刺包",
        "week_start": week_start.isoformat(),
        "daily_minutes": daily_minutes,
        "student": user.display_name or user.email.split("@")[0],
        "instructions": [
            "每天只做一頁，時間到即可停止。",
            "先遮住答案回想，再用答案頁訂正。",
            "回到 App 輸入完成碼，可同步成長點數與學習紀錄。",
        ],
        "days": days,
    }


@app.post("/user/weekly-study-pack", response_model=WeeklyStudyPackResponse)
def create_weekly_study_pack(
    request: WeeklyStudyPackCreateRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> WeeklyStudyPackResponse:
    preference = get_or_create_learning_preference(db, current_user.id)
    requested_week = request.week_start or _week_start(_local_today(preference))
    requested_week = _week_start(requested_week)
    if abs((requested_week - _local_today(preference)).days) > 370:
        raise HTTPException(status_code=422, detail="Study pack week is outside the allowed range.")
    daily_minutes = int(request.daily_minutes or preference.preferred_session_minutes or 10)
    daily_minutes = max(5, min(30, daily_minutes))
    pack = db.scalar(
        select(WeeklyStudyPack).where(
            WeeklyStudyPack.user_id == current_user.id,
            WeeklyStudyPack.week_start == requested_week,
        )
    )
    if pack is not None and not request.regenerate:
        return _study_pack_response(pack)

    payload = _build_weekly_study_pack_payload(
        db,
        current_user,
        week_start=requested_week,
        daily_minutes=daily_minutes,
    )
    if pack is None:
        pack = WeeklyStudyPack(
            id=secrets.token_hex(16),
            user_id=current_user.id,
            week_start=requested_week,
            pack_code=_weekly_pack_code(db),
            daily_minutes=daily_minutes,
            status="ready",
            payload_json=json.dumps(payload, ensure_ascii=False),
            completed_days_json="[]",
        )
        db.add(pack)
    else:
        pack.daily_minutes = daily_minutes
        pack.payload_json = json.dumps(payload, ensure_ascii=False)
        pack.generated_at = datetime.utcnow()
    db.commit()
    db.refresh(pack)
    return _study_pack_response(pack)


@app.get("/user/weekly-study-pack/latest", response_model=WeeklyStudyPackResponse)
def get_latest_weekly_study_pack(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> WeeklyStudyPackResponse:
    pack = db.scalar(
        select(WeeklyStudyPack)
        .where(WeeklyStudyPack.user_id == current_user.id)
        .order_by(WeeklyStudyPack.week_start.desc(), WeeklyStudyPack.generated_at.desc())
        .limit(1)
    )
    if pack is None:
        raise HTTPException(status_code=404, detail="No weekly study pack has been generated.")
    return _study_pack_response(pack)


@app.post("/user/weekly-study-pack/complete", response_model=WeeklyStudyPackCompleteResponse)
def complete_weekly_study_pack(
    request: WeeklyStudyPackCompleteRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> WeeklyStudyPackCompleteResponse:
    normalized_code = request.pack_code.strip().upper()
    pack = db.scalar(
        select(WeeklyStudyPack).where(
            WeeklyStudyPack.user_id == current_user.id,
            WeeklyStudyPack.pack_code == normalized_code,
        )
    )
    if pack is None:
        raise HTTPException(status_code=404, detail="Study pack completion code is invalid.")
    requested_days = sorted({int(day) for day in request.completed_days})
    if not requested_days or any(day < 1 or day > 5 for day in requested_days):
        raise HTTPException(status_code=422, detail="Completed days must be between 1 and 5.")
    try:
        prior_days = {int(day) for day in json.loads(pack.completed_days_json or "[]")}
    except (TypeError, ValueError, json.JSONDecodeError):
        prior_days = set()
    newly_completed = [day for day in requested_days if day not in prior_days]
    aggregate_points = 0
    any_level_up = False
    for day in newly_completed:
        feedback = record_learning_event(
            db,
            user=current_user,
            source_key=f"user:{current_user.id}:paper-pack:{pack.id}:day:{day}",
            event_type="paper_day_completed",
            skill="mixed",
            outcome="completed",
            points=14,
            message="你在沒有手機的情況下也完成了學習，這份自律已經記錄下來。",
            metadata={"pack_id": pack.id, "day": day},
        )
        if feedback.awarded:
            aggregate_points += feedback.points
            any_level_up = any_level_up or feedback.level_up
    all_days = sorted(prior_days.union(requested_days))
    pack.completed_days_json = json.dumps(all_days)
    if len(all_days) >= 5:
        pack.status = "completed"
        pack.completed_at = datetime.utcnow()
    state = get_or_create_reward_state(db, current_user.id)
    db.commit()
    db.refresh(pack)
    reward = RewardFeedback(
        awarded=bool(newly_completed),
        points=aggregate_points,
        message=(
            f"已同步 {len(newly_completed)} 天紙本學習，手機不在身邊也沒有中斷進步。"
            if newly_completed
            else "這些紙本學習日已經同步過，不會重複計分。"
        ),
        total_points=int(state.total_points or 0),
        level=int(state.level or 1),
        level_up=any_level_up,
    )
    return WeeklyStudyPackCompleteResponse(
        pack=_study_pack_response(pack),
        reward=reward,
        summary=build_reward_summary(db, current_user),
    )


@app.get("/user/weekly-study-pack/{pack_id}/pdf")
def download_weekly_study_pack_pdf(
    pack_id: str,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> StreamingResponse:
    if SimpleDocTemplate is None:
        raise HTTPException(status_code=500, detail="PDF export requires reportlab.")
    pack = db.scalar(
        select(WeeklyStudyPack).where(
            WeeklyStudyPack.id == pack_id,
            WeeklyStudyPack.user_id == current_user.id,
        )
    )
    if pack is None:
        raise HTTPException(status_code=404, detail="Weekly study pack not found.")
    try:
        payload = json.loads(pack.payload_json)
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=500, detail="Study pack data is corrupted.") from exc
    pdf_buffer = BytesIO()
    _build_weekly_study_pack_pdf(pdf_buffer, pack=pack, payload=payload)
    pdf_buffer.seek(0)
    pack.last_downloaded_at = datetime.utcnow()
    db.commit()
    filename = f"gsat-max-study-pack-{pack.week_start.isoformat()}.pdf"
    return StreamingResponse(
        pdf_buffer,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@app.post("/admin/seed-gsat", response_model=GSATSeedResponse)
def seed_gsat_reference_papers(
    papers: list[GSATReferencePaperSeedItem],
    db: Session = Depends(get_db),
    current_user: User = Depends(get_admin_user),
) -> GSATSeedResponse:
    inserted = 0
    for paper in papers:
        content = paper.content.strip()
        if not content:
            continue
        reference = GSATReferencePaper(
            year=paper.year,
            exam_type=normalize_gsat_exam_type(paper.exam_type),
            content=content,
            json_structure=serialize_json_structure(paper.json_structure),
        )
        db.add(reference)
        inserted += 1

    db.commit()
    total = db.scalar(select(func.count(GSATReferencePaper.id))) or 0
    return GSATSeedResponse(
        inserted=inserted,
        total_reference_papers=int(total),
    )


@app.get("/user/export-cheat-sheet")
def export_cheat_sheet(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> StreamingResponse:
    if SimpleDocTemplate is None:
        raise HTTPException(
            status_code=500,
            detail="PDF export requires reportlab. Install backend dependencies from requirements.txt.",
        )

    hard_vocab_rows = db.execute(
        select(Vocabulary, UserVocabProgress)
        .join(UserVocabProgress, UserVocabProgress.vocab_id == Vocabulary.id)
        .where(UserVocabProgress.user_id == current_user.id)
        .order_by(
            UserVocabProgress.ease_factor.asc(),
            UserVocabProgress.repetitions.asc(),
            UserVocabProgress.interval.asc(),
            UserVocabProgress.updated_at.desc(),
        )
        .limit(20)
    ).all()

    concept_rows = db.execute(
        select(
            GrammarErrorLedger.error_type,
            func.count(GrammarErrorLedger.id).label("entry_count"),
            func.sum(GrammarErrorLedger.occurrence_count).label("occurrences"),
        )
        .where(
            GrammarErrorLedger.user_id == current_user.id,
            GrammarErrorLedger.is_mastered.is_(False),
        )
        .group_by(GrammarErrorLedger.error_type)
        .order_by(
            func.sum(GrammarErrorLedger.occurrence_count).desc(),
            func.count(GrammarErrorLedger.id).desc(),
        )
        .limit(5)
    ).all()

    grammar_concepts: list[dict[str, Any]] = []
    for concept, entry_count, occurrences in concept_rows:
        sample = db.scalar(
            select(GrammarErrorLedger)
            .where(
                GrammarErrorLedger.user_id == current_user.id,
                GrammarErrorLedger.error_type == concept,
                GrammarErrorLedger.is_mastered.is_(False),
            )
            .order_by(
                GrammarErrorLedger.occurrence_count.desc(),
                GrammarErrorLedger.updated_at.desc(),
            )
            .limit(1)
        )
        grammar_concepts.append(
            {
                "concept": concept,
                "entry_count": int(entry_count or 0),
                "occurrences": int(occurrences or 0),
                "sample": sample,
            }
        )

    pdf_buffer = BytesIO()
    _build_cheat_sheet_pdf(
        pdf_buffer=pdf_buffer,
        user=current_user,
        hard_vocab_rows=hard_vocab_rows,
        grammar_concepts=grammar_concepts,
    )
    pdf_buffer.seek(0)

    filename = f"gsat-final-week-cheat-sheet-{current_user.id}.pdf"
    headers = {"Content-Disposition": f'attachment; filename="{filename}"'}
    return StreamingResponse(
        pdf_buffer,
        media_type="application/pdf",
        headers=headers,
    )


def _build_weekly_study_pack_pdf(
    pdf_buffer: BytesIO,
    *,
    pack: WeeklyStudyPack,
    payload: dict[str, Any],
) -> None:
    body_font = _register_cheat_sheet_body_font()
    doc = SimpleDocTemplate(
        pdf_buffer,
        pagesize=A4,
        rightMargin=16 * mm,
        leftMargin=16 * mm,
        topMargin=15 * mm,
        bottomMargin=15 * mm,
        title="GSAT_Max Weekly Study Pack",
    )
    styles = getSampleStyleSheet()
    styles.add(
        ParagraphStyle(
            name="PackTitle",
            parent=styles["Title"],
            fontName=body_font,
            fontSize=20,
            leading=26,
            alignment=TA_CENTER,
            textColor=colors.HexColor("#111111"),
            spaceAfter=8,
        )
    )
    styles.add(
        ParagraphStyle(
            name="PackHeading",
            parent=styles["Heading2"],
            fontName=body_font,
            fontSize=13,
            leading=18,
            textColor=colors.HexColor("#111111"),
            spaceBefore=8,
            spaceAfter=6,
        )
    )
    styles.add(
        ParagraphStyle(
            name="PackBody",
            parent=styles["BodyText"],
            fontName=body_font,
            fontSize=9,
            leading=14,
            textColor=colors.HexColor("#222222"),
            spaceAfter=5,
        )
    )
    styles.add(
        ParagraphStyle(
            name="PackSmall",
            parent=styles["BodyText"],
            fontName=body_font,
            fontSize=8,
            leading=11,
            textColor=colors.HexColor("#444444"),
        )
    )
    story: list[Any] = [
        Spacer(1, 20 * mm),
        Paragraph(_pdf_escape(payload.get("title", "GSAT_Max 五日紙本衝刺包")), styles["PackTitle"]),
        Paragraph(
            _pdf_escape(
                f"學生：{payload.get('student', '')}　週次：{pack.week_start.isoformat()}　"
                f"每日約 {pack.daily_minutes} 分鐘"
            ),
            styles["PackBody"],
        ),
        Spacer(1, 8 * mm),
    ]
    instructions = payload.get("instructions", [])
    for index, instruction in enumerate(instructions, start=1):
        story.append(Paragraph(f"{index}. {_pdf_escape(instruction)}", styles["PackBody"]))
    story.extend(
        [
            Spacer(1, 12 * mm),
            Paragraph("完成方式", styles["PackHeading"]),
            Paragraph(
                "每天完成一頁後打勾。下次打開 App 時輸入下方完成碼，系統會同步紙本進度與成長點數。",
                styles["PackBody"],
            ),
            Spacer(1, 5 * mm),
            Table(
                [[Paragraph("完成碼", styles["PackBody"]), Paragraph(f"<b>{pack.pack_code}</b>", styles["PackTitle"])]],
                colWidths=[35 * mm, 110 * mm],
                style=TableStyle(
                    [
                        ("BOX", (0, 0), (-1, -1), 1.2, colors.black),
                        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                        ("ALIGN", (1, 0), (1, 0), "CENTER"),
                        ("TOPPADDING", (0, 0), (-1, -1), 9),
                        ("BOTTOMPADDING", (0, 0), (-1, -1), 9),
                    ]
                ),
            ),
            Spacer(1, 18 * mm),
            Paragraph("家長／老師簽名：____________________________", styles["PackBody"]),
        ]
    )

    days = payload.get("days", [])
    for day in days:
        story.extend(
            [
                PageBreak(),
                Paragraph(
                    _pdf_escape(f"{day.get('title', 'Daily Sprint')}　{day.get('date', '')}"),
                    styles["PackTitle"],
                ),
                Paragraph(
                    f"□ 開始　□ 完成　建議時間：{int(day.get('minutes', pack.daily_minutes))} 分鐘",
                    styles["PackBody"],
                ),
                Paragraph("A. 單字快速回想", styles["PackHeading"]),
            ]
        )
        vocab_data = [
            [
                Paragraph("<b>Word</b>", styles["PackSmall"]),
                Paragraph("<b>先遮住答案，寫下中文意思</b>", styles["PackSmall"]),
                Paragraph("<b>用法提示</b>", styles["PackSmall"]),
            ]
        ]
        for item in day.get("vocabulary", []):
            vocab_data.append(
                [
                    Paragraph(f"<b>{_pdf_escape(item.get('word'))}</b>", styles["PackSmall"]),
                    Paragraph("________________________________", styles["PackSmall"]),
                    Paragraph(_pdf_escape(_clip_text(str(item.get("example", "")), 110)), styles["PackSmall"]),
                ]
            )
        vocab_table = Table(vocab_data, colWidths=[34 * mm, 65 * mm, 79 * mm], repeatRows=1)
        vocab_table.setStyle(_weekly_pack_table_style())
        story.append(vocab_table)

        grammar = day.get("grammar", {})
        reading = day.get("reading", {})
        story.extend(
            [
                Paragraph("B. 文法弱點修復", styles["PackHeading"]),
                Paragraph(f"概念：<b>{_pdf_escape(grammar.get('concept', 'Grammar'))}</b>", styles["PackBody"]),
                Paragraph(_pdf_escape(grammar.get("question", "")), styles["PackBody"]),
                Paragraph("我的改寫：____________________________________________________________", styles["PackBody"]),
                Paragraph("C. 短篇閱讀", styles["PackHeading"]),
                Paragraph(_pdf_escape(reading.get("text", "")), styles["PackBody"]),
            ]
        )
        for index, question in enumerate(reading.get("questions", []), start=1):
            story.extend(
                [
                    Paragraph(f"{index}. {_pdf_escape(question)}", styles["PackBody"]),
                    Paragraph("______________________________________________________________________", styles["PackSmall"]),
                ]
            )
        story.extend(
            [
                Paragraph("D. 今天的勝利證據", styles["PackHeading"]),
                Paragraph(_pdf_escape(day.get("reflection", "")), styles["PackBody"]),
                Paragraph("難度感受：□ 比想像中容易　□ 剛剛好　□ 需要再練一次", styles["PackBody"]),
            ]
        )

    story.extend([PageBreak(), Paragraph("答案與訂正頁", styles["PackTitle"])])
    for day in days:
        grammar = day.get("grammar", {})
        reading = day.get("reading", {})
        answer_parts = [
            Paragraph(f"<b>Day {day.get('day')}</b>", styles["PackHeading"]),
            Paragraph(
                "單字：" + "；".join(
                    f"{_pdf_escape(item.get('word'))} = {_pdf_escape(item.get('meaning'))}"
                    for item in day.get("vocabulary", [])
                ),
                styles["PackSmall"],
            ),
            Paragraph(
                "文法：" + _pdf_escape(grammar.get("correct_answer", "")),
                styles["PackSmall"],
            ),
            Paragraph(
                "解析：" + _pdf_escape(grammar.get("explanation", "")),
                styles["PackSmall"],
            ),
        ]
        for index, answer in enumerate(reading.get("answers", []), start=1):
            answer_parts.append(
                Paragraph(f"閱讀 {index}：{_pdf_escape(answer)}", styles["PackSmall"])
            )
        story.append(KeepTogether(answer_parts))
        story.append(Spacer(1, 4 * mm))

    doc.build(
        story,
        onFirstPage=_draw_weekly_pack_watermark,
        onLaterPages=_draw_weekly_pack_watermark,
    )


def _weekly_pack_table_style() -> TableStyle:
    return TableStyle(
        [
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#E5E7EB")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.black),
            ("FONTNAME", (0, 0), (-1, 0), "Helvetica-Bold"),
            ("GRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#777777")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("LEFTPADDING", (0, 0), (-1, -1), 5),
            ("RIGHTPADDING", (0, 0), (-1, -1), 5),
            ("TOPPADDING", (0, 0), (-1, -1), 6),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ]
    )


def _draw_weekly_pack_watermark(canvas: Any, doc: SimpleDocTemplate) -> None:
    canvas.saveState()
    canvas.setFont("Helvetica-Bold", 28)
    canvas.setFillColor(colors.Color(0.05, 0.05, 0.05, alpha=0.035))
    canvas.translate(A4[0] / 2, A4[1] / 2)
    canvas.rotate(32)
    canvas.drawCentredString(0, 0, "GSAT_MAX WEEKLY SPRINT")
    canvas.restoreState()
    canvas.saveState()
    canvas.setFont("Helvetica", 7)
    canvas.setFillColor(colors.HexColor("#777777"))
    canvas.drawString(16 * mm, 9 * mm, "Generated by GSAT_Max - GSAT English Master")
    canvas.drawRightString(A4[0] - 16 * mm, 9 * mm, f"Page {doc.page}")
    canvas.restoreState()


def _build_cheat_sheet_pdf(
    *,
    pdf_buffer: BytesIO,
    user: User,
    hard_vocab_rows: list[Any],
    grammar_concepts: list[dict[str, Any]],
) -> None:
    doc = SimpleDocTemplate(
        pdf_buffer,
        pagesize=A4,
        rightMargin=16 * mm,
        leftMargin=16 * mm,
        topMargin=15 * mm,
        bottomMargin=15 * mm,
        title="Final Week GSAT Cheat Sheet",
    )
    styles = getSampleStyleSheet()
    body_font = _register_cheat_sheet_body_font()
    styles.add(
        ParagraphStyle(
            name="CheatTitle",
            parent=styles["Title"],
            fontName="Helvetica-Bold",
            fontSize=20,
            leading=24,
            textColor=colors.HexColor("#111827"),
            alignment=TA_CENTER,
            spaceAfter=6,
        )
    )
    styles.add(
        ParagraphStyle(
            name="CheatSubtitle",
            parent=styles["BodyText"],
            fontName=body_font,
            fontSize=9,
            leading=12,
            textColor=colors.HexColor("#4B5563"),
            alignment=TA_CENTER,
            spaceAfter=12,
        )
    )
    styles.add(
        ParagraphStyle(
            name="SectionHeading",
            parent=styles["Heading2"],
            fontName="Helvetica-Bold",
            fontSize=13,
            leading=16,
            textColor=colors.HexColor("#0F766E"),
            spaceBefore=8,
            spaceAfter=6,
        )
    )
    styles.add(
        ParagraphStyle(
            name="SmallText",
            parent=styles["BodyText"],
            fontName=body_font,
            fontSize=8,
            leading=10,
            textColor=colors.HexColor("#374151"),
        )
    )
    styles.add(
        ParagraphStyle(
            name="TinyMuted",
            parent=styles["BodyText"],
            fontName=body_font,
            fontSize=7,
            leading=9,
            textColor=colors.HexColor("#6B7280"),
        )
    )

    story: list[Any] = [
        Paragraph("Final Week GSAT English Cheat Sheet", styles["CheatTitle"]),
        Paragraph(
            f"Personal weak-point review for {_pdf_escape(user.display_name or user.email)} "
            f"generated on {datetime.utcnow().strftime('%Y-%m-%d')}",
            styles["CheatSubtitle"],
        ),
        Paragraph("Top 20 Hard Vocabulary Words", styles["SectionHeading"]),
    ]

    if hard_vocab_rows:
        vocab_table_data = [
            [
                Paragraph("<b>#</b>", styles["SmallText"]),
                Paragraph("<b>Word</b>", styles["SmallText"]),
                Paragraph("<b>Meaning / Note</b>", styles["SmallText"]),
                Paragraph("<b>Review Signal</b>", styles["SmallText"]),
            ]
        ]
        for index, (vocabulary, progress) in enumerate(hard_vocab_rows, start=1):
            meaning = vocabulary.definition or vocabulary.source_context or "Add a concise Chinese meaning here."
            vocab_table_data.append(
                [
                    Paragraph(str(index), styles["SmallText"]),
                    Paragraph(f"<b>{_pdf_escape(vocabulary.word)}</b>", styles["SmallText"]),
                    Paragraph(_pdf_escape(_clip_text(meaning, 170)), styles["SmallText"]),
                    Paragraph(
                        _pdf_escape(
                            f"EF {progress.ease_factor:.2f} | reps {progress.repetitions} | interval {progress.interval}d"
                        ),
                        styles["TinyMuted"],
                    ),
                ]
            )
        table = Table(vocab_table_data, colWidths=[9 * mm, 30 * mm, 92 * mm, 47 * mm])
        table.setStyle(_cheat_sheet_table_style())
        story.append(table)
    else:
        story.append(
            Paragraph(
                "No hard vocabulary has been recorded yet. Tap difficult words in Reading to build this list.",
                styles["SmallText"],
            )
        )

    story.extend(
        [
            Spacer(1, 8 * mm),
            Paragraph("Top 5 Unmastered Grammar Concepts", styles["SectionHeading"]),
        ]
    )

    if grammar_concepts:
        grammar_table_data = [
            [
                Paragraph("<b>#</b>", styles["SmallText"]),
                Paragraph("<b>Concept</b>", styles["SmallText"]),
                Paragraph("<b>What to Review</b>", styles["SmallText"]),
                Paragraph("<b>Signal</b>", styles["SmallText"]),
            ]
        ]
        for index, item in enumerate(grammar_concepts, start=1):
            sample = item["sample"]
            review_note = "Review the rule and write one corrected sentence."
            if sample is not None:
                parts = [
                    f"Missed: {sample.original_sentence}",
                    f"Correct: {sample.corrected_sentence or 'Check the correct form.'}",
                    sample.explanation or "",
                ]
                review_note = " | ".join(part for part in parts if part)

            grammar_table_data.append(
                [
                    Paragraph(str(index), styles["SmallText"]),
                    Paragraph(f"<b>{_pdf_escape(_titleize_concept(item['concept']))}</b>", styles["SmallText"]),
                    Paragraph(_pdf_escape(_clip_text(review_note, 240)), styles["SmallText"]),
                    Paragraph(
                        _pdf_escape(
                            f"{item['occurrences']} misses across {item['entry_count']} saved entries"
                        ),
                        styles["TinyMuted"],
                    ),
                ]
            )
        table = Table(grammar_table_data, colWidths=[9 * mm, 39 * mm, 92 * mm, 38 * mm])
        table.setStyle(_cheat_sheet_table_style())
        story.append(table)
    else:
        story.append(
            Paragraph(
                "No unmastered grammar concepts are currently saved. Use the Error Ledger to track misses.",
                styles["SmallText"],
            )
        )

    story.extend(
        [
            Spacer(1, 8 * mm),
            Paragraph(
                "Last-minute routine: read this sheet aloud, cover the right column, recall each meaning/rule, then write one original sentence for every missed item.",
                styles["SmallText"],
            ),
            Spacer(1, 6 * mm),
            Paragraph(
                "Generated by GSAT_Max",
                styles["CheatSubtitle"],
            ),
        ]
    )

    doc.build(story, onFirstPage=_draw_cheat_sheet_watermark, onLaterPages=_draw_cheat_sheet_watermark)


def _register_cheat_sheet_body_font() -> str:
    if pdfmetrics is None:
        return "Helvetica"
    bundled_font = Path(__file__).resolve().parent / "assets" / "fonts" / "NotoSansTC-Regular.ttf"
    if TTFont is not None and bundled_font.is_file():
        font_name = "GSATMaxNotoSansTC"
        try:
            if font_name not in pdfmetrics.getRegisteredFontNames():
                pdfmetrics.registerFont(TTFont(font_name, str(bundled_font)))
            return font_name
        except Exception:
            pass
    if UnicodeCIDFont is None:
        return "Helvetica"
    for font_name in ("MSung-Light", "STSong-Light"):
        try:
            pdfmetrics.registerFont(UnicodeCIDFont(font_name))
            return font_name
        except Exception:
            continue
    return "Helvetica"


def _cheat_sheet_table_style() -> TableStyle:
    return TableStyle(
        [
            ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#ECFDF5")),
            ("TEXTCOLOR", (0, 0), (-1, 0), colors.HexColor("#064E3B")),
            ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#D1D5DB")),
            ("VALIGN", (0, 0), (-1, -1), "TOP"),
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#F9FAFB")]),
            ("LEFTPADDING", (0, 0), (-1, -1), 5),
            ("RIGHTPADDING", (0, 0), (-1, -1), 5),
            ("TOPPADDING", (0, 0), (-1, -1), 5),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ]
    )


def _draw_cheat_sheet_watermark(canvas: Any, doc: SimpleDocTemplate) -> None:
    canvas.saveState()
    canvas.setFont("Helvetica-Bold", 32)
    canvas.setFillColor(colors.Color(0.1, 0.1, 0.1, alpha=0.045))
    canvas.translate(A4[0] / 2, A4[1] / 2)
    canvas.rotate(34)
    canvas.drawCentredString(0, 0, "GSAT ENGLISH MASTER")
    canvas.restoreState()

    canvas.saveState()
    canvas.setFont("Helvetica", 7)
    canvas.setFillColor(colors.HexColor("#9CA3AF"))
    canvas.drawRightString(A4[0] - 16 * mm, 10 * mm, f"Page {doc.page}")
    canvas.restoreState()


def _pdf_escape(value: Any) -> str:
    return html.escape(str(value or ""), quote=True)


def _clip_text(value: str, limit: int) -> str:
    compact = re.sub(r"\s+", " ", value).strip()
    if len(compact) <= limit:
        return compact
    return compact[: limit - 1].rstrip() + "..."


def _titleize_concept(concept: str) -> str:
    return re.sub(r"[_-]+", " ", concept or "grammar").strip().title()


def build_fallback_full_mock_exam() -> dict[str, Any]:
    def mcq(number: int, part: str, stem: str, options: list[str], correct: int = 0) -> dict[str, Any]:
        return {
            "number": number,
            "type": part,
            "stem": stem,
            "options": options,
            "correct_option_index": correct,
            "explanation": "Review the tested GSAT pattern and eliminate distractors by meaning and grammar.",
        }

    sections = [
        {
            "part": 1,
            "title": "Vocabulary",
            "subtitle": "Questions 1-10",
            "instructions": "Choose the word or phrase that best completes each sentence.",
            "questions": [
                mcq(i, "vocabulary", f"Question {i}: The school introduced a new program to ____ students' reading habits.", ["improve", "ignore", "remove", "predict"])
                for i in range(1, 11)
            ],
        },
        {
            "part": 2,
            "title": "Cloze Test (克漏字)",
            "subtitle": "Questions 11-20",
            "passage": "Many students believe progress comes from long study sessions. However, research suggests that small habits repeated every day can be more effective.",
            "instructions": "Read the passage and choose the best answer for each blank.",
            "questions": [
                mcq(i, "cloze", f"Blank {i - 10}: Choose the best word for the passage.", ["therefore", "although", "unless", "besides"])
                for i in range(11, 21)
            ],
        },
        {
            "part": 3,
            "title": "Passage Completion (文意選填)",
            "subtitle": "Questions 21-30",
            "passage": "A useful review plan connects vocabulary, grammar, and reading. [BLANKS] Students who notice patterns learn faster.",
            "instructions": "Choose the most suitable sentence or phrase for each blank.",
            "questions": [
                mcq(i, "passage_completion", f"Blank {i - 20}: Select the sentence that best fits.", ["This helps them remember language in context.", "The weather changed quickly.", "Sports are popular worldwide.", "The room was painted blue."])
                for i in range(21, 31)
            ],
        },
        {
            "part": 4,
            "title": "Discourse Structure (篇章結構)",
            "subtitle": "Questions 31-34",
            "passage": "Paragraph 1 introduces the issue. [BLANK_31] Paragraph 2 gives evidence. [BLANK_32] Paragraph 3 discusses limits. [BLANK_33] Paragraph 4 concludes. [BLANK_34]",
            "instructions": "Choose the sentence that best restores the article structure.",
            "questions": [
                mcq(i, "discourse_structure", f"Blank {i}: Choose the best sentence.", ["This transition clarifies the connection between ideas.", "This unrelated fact distracts readers.", "This example changes the topic suddenly.", "This ending repeats no useful idea."])
                for i in range(31, 35)
            ],
        },
        {
            "part": 5,
            "title": "Reading Comprehension (閱讀測驗)",
            "subtitle": "Questions 35-46",
            "passages": [
                {
                    "title": "Learning in Small Steps",
                    "text": "A growing number of students use short daily practice to prepare for major exams. The method is simple: review often, test yourself, and correct mistakes quickly.",
                }
            ],
            "instructions": "Choose the best answer according to the passage.",
            "questions": [
                mcq(i, "reading_comprehension", f"Question {i}: What is the main idea of the passage?", ["Small repeated practice can improve learning.", "Students should avoid all technology.", "Long study sessions are always best.", "Mistakes should never be reviewed."])
                for i in range(35, 47)
            ],
        },
        {
            "part": 6,
            "title": "Mixed Question Types (混合題)",
            "subtitle": "Questions 47-56",
            "passage": "The table compares two student study plans. Plan A uses daily review, while Plan B uses one long weekly session.",
            "instructions": "Answer vocabulary, inference, chart-reading, and grammar questions.",
            "questions": [
                mcq(i, "mixed", f"Question {i}: Based on the information, which statement is best supported?", ["Daily review supports steady memory.", "Weekly study always fails.", "Charts cannot show learning habits.", "Vocabulary is unrelated to reading."])
                for i in range(47, 57)
            ],
        },
    ]
    return {
        "title": "GSAT English Full Mock Exam Set",
        "sections": sections,
        "non_choice": {
            "translation": {
                "zh_to_en": "穩定的練習能幫助學生在考試中更有自信。",
                "en_to_zh": "Students who review their mistakes carefully often improve faster.",
            },
            "essay": {
                "prompt": "Some students prefer short daily practice, while others study for many hours before exams. Which method do you think is more effective? Write about 120 words and explain your opinion with reasons and examples.",
            },
        },
    }


def build_fallback_mixed_questions() -> dict[str, Any]:
    return {
        "text_a": (
            "Many Taiwanese students now use digital planners to organize their exam "
            "preparation. Instead of studying only when a test is near, they divide "
            "large goals into short daily missions. A typical plan may include "
            "vocabulary review, one reading passage, and a short writing sprint. "
            "Teachers say this approach helps students notice weak points earlier. "
            "However, the method works only when learners review mistakes carefully "
            "and adjust the next day's schedule. In other words, technology is useful "
            "not because it replaces effort, but because it makes effort easier to see."
        ),
        "text_b": (
            "Memo: Grade 12 English Sprint Data\n"
            "Week 1: 38% of students completed all daily missions.\n"
            "Week 2: 54% completed all missions after reminders were added.\n"
            "Week 3: 61% completed all missions and reported lower test anxiety."
        ),
        "multiple_choice": [
            {
                "number": 47,
                "question": "What is the main idea shared by Text A and Text B?",
                "options": [
                    "Daily planning can make exam preparation more consistent.",
                    "Students should stop using technology while studying.",
                    "Writing practice is less useful than vocabulary review.",
                    "Weekly tests are the only way to reduce anxiety.",
                ],
                "correct_option_index": 0,
                "explanation": "Both texts emphasize daily missions and consistent preparation.",
            },
            {
                "number": 48,
                "question": "According to Text B, what happened after reminders were added?",
                "options": [
                    "Completion increased from 38% to 54%.",
                    "Completion dropped below 38%.",
                    "All students finished every mission.",
                    "Students stopped reporting anxiety.",
                ],
                "correct_option_index": 0,
                "explanation": "The memo states Week 2 completion rose to 54% after reminders.",
            },
            {
                "number": 49,
                "question": "Which statement is best supported by Text A?",
                "options": [
                    "Technology is helpful when students still reflect and work.",
                    "Technology can replace careful review.",
                    "Students should study only before major exams.",
                    "Teachers believe mistakes should be ignored.",
                ],
                "correct_option_index": 0,
                "explanation": "Text A says technology helps make effort visible, not replace it.",
            },
        ],
        "short_answer": [
            {
                "number": 50,
                "question": "In one sentence, explain why technology is useful according to Text A.",
                "reference_answer": "Technology is useful because it helps students see and adjust their effort.",
                "max_score": 2,
                "rubric": "2 points for mentioning visible effort and adjustment; 1 point for only mentioning organization or planning.",
            },
            {
                "number": 51,
                "question": "Use Text B to describe one trend in student behavior.",
                "reference_answer": "The percentage of students completing all daily missions increased over the three weeks.",
                "max_score": 2,
                "rubric": "2 points for identifying the upward completion trend with evidence; 1 point for a vague increase without data.",
            },
        ],
    }


GSAT_HIGH_FREQUENCY_PHRASES = [
    "take for granted",
    "come up with",
    "keep up with",
    "make up for",
    "look forward to",
    "pay attention to",
    "get along with",
    "put off",
    "run out of",
    "take advantage of",
    "be aware of",
    "be responsible for",
    "in addition to",
    "as a result of",
    "play an important role in",
]


def build_fallback_cloze_phrases() -> dict[str, Any]:
    phrases = GSAT_HIGH_FREQUENCY_PHRASES[:10]
    text_value = (
        "During the final month before the GSAT, Maya promised not to [BLANK_1] "
        "quiet study time. She asked her teacher to help her [BLANK_2] a weekly "
        "plan that she could actually follow. Because news articles were difficult, "
        "she worked hard to [BLANK_3] classmates who read faster. When she missed "
        "practice on Monday, she tried to [BLANK_4] it by reviewing extra phrases "
        "on Tuesday. She began to [BLANK_5] English class because each lesson felt "
        "useful. During reading practice, she learned to [BLANK_6] transition words "
        "and collocations. Group study helped her [BLANK_7] friends who shared the "
        "same goal. She stopped trying to [BLANK_8] hard essays. When she nearly "
        "[BLANK_9] energy, she took a short break. Finally, she learned to [BLANK_10] "
        "mock exams as chances to improve."
    )
    return {
        "text": text_value,
        "phrases": phrases,
        "correct_mapping": {f"BLANK_{index}": phrase for index, phrase in enumerate(phrases, start=1)},
    }


def build_fallback_sentence_upgrade(focus: str | None = None) -> dict[str, str]:
    target = focus or "Participle Clause"
    examples = {
        "inversion": {
            "basic_sentence": "I had never seen such a difficult question. I felt nervous.",
            "target_structure": "Inversion",
            "instruction": "Rewrite the sentence using inversion, such as 'Never had I...'.",
        },
        "participle_clause": {
            "basic_sentence": "The weather was bad. We stayed home.",
            "target_structure": "Participle Clause",
            "instruction": "Rewrite the sentence using a participle clause to combine the ideas.",
        },
        "relative_clause": {
            "basic_sentence": "I met a teacher. The teacher changed my study habits.",
            "target_structure": "Relative Clause",
            "instruction": "Rewrite the sentence using a relative clause.",
        },
    }
    key = normalize_concept(target)
    return examples.get(
        key,
        {
            "basic_sentence": "The weather was bad. We stayed home.",
            "target_structure": target,
            "instruction": f"Rewrite the sentence using {target}.",
        },
    )


@app.post("/user/initialize", response_model=UserInitializeResponse)
def initialize_user(
    request: UserInitializeRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> UserInitializeResponse:
    user = db.get(User, current_user.id)
    if user is None:
        raise HTTPException(status_code=401, detail="Token user no longer exists.")

    correct_count = sum(1 for answer in request.answers if answer.is_correct)
    total_questions = max(1, len(request.answers))
    normalized_score = correct_count / total_questions
    vocab_total = sum(1 for answer in request.answers if answer.category == "vocab")
    vocab_correct = sum(
        1 for answer in request.answers if answer.category == "vocab" and answer.is_correct
    )
    grammar_total = sum(1 for answer in request.answers if answer.category == "grammar")
    grammar_correct = sum(
        1
        for answer in request.answers
        if answer.category == "grammar" and answer.is_correct
    )

    user.skill_vocabulary = round(vocab_correct / max(1, vocab_total), 2)
    user.skill_grammar = round(grammar_correct / max(1, grammar_total), 2)
    user.skill_reading = round(min(1.0, 0.42 + normalized_score * 0.46), 2)
    user.skill_writing = round(min(1.0, 0.32 + normalized_score * 0.42), 2)
    user.grammar_score_total = user.skill_grammar * 5
    user.grammar_score_count = 1
    user.has_completed_onboarding = True

    seeded_words = seed_initial_vocab_progress(db, user, normalized_score)
    db.commit()
    db.refresh(user)

    return UserInitializeResponse(
        seeded_words=seeded_words,
        correct_count=correct_count,
        has_completed_onboarding=True,
        stats=build_user_stats(db, user),
    )


def seed_initial_vocab_progress(
    db: Session,
    user: User,
    normalized_score: float,
) -> int:
    now = datetime.utcnow()
    seeded_count = 0

    if normalized_score >= 0.8:
        easy_template = {"interval": 7, "repetitions": 3, "next_review_date": now + timedelta(days=7)}
        hard_template = {"interval": 0, "repetitions": 0, "next_review_date": now}
    elif normalized_score >= 0.5:
        easy_template = {"interval": 3, "repetitions": 2, "next_review_date": now + timedelta(days=3)}
        hard_template = {"interval": 1, "repetitions": 0, "next_review_date": now + timedelta(days=1)}
    else:
        easy_template = {"interval": 0, "repetitions": 0, "next_review_date": now}
        hard_template = {"interval": 2, "repetitions": 0, "next_review_date": now + timedelta(days=2)}

    seed_entries = [
        *[
            (word, definition, example, easy_template)
            for word, definition, example in INITIAL_EASY_GSAT_WORDS
        ],
        *[
            (word, definition, example, hard_template)
            for word, definition, example in INITIAL_HARD_GSAT_WORDS
        ],
    ]

    for word, definition, example, template in seed_entries:
        normalized_word = normalize_word(word)
        vocabulary = db.scalar(select(Vocabulary).where(Vocabulary.word == normalized_word))
        if vocabulary is None:
            vocabulary = Vocabulary(
                word=normalized_word,
                definition=definition,
                source_context=example,
            )
            db.add(vocabulary)
            db.flush()
        else:
            if not vocabulary.definition:
                vocabulary.definition = definition
            if not vocabulary.source_context:
                vocabulary.source_context = example

        progress = db.scalar(
            select(UserVocabProgress).where(
                UserVocabProgress.user_id == user.id,
                UserVocabProgress.vocab_id == vocabulary.id,
            )
        )
        if progress is None:
            progress = UserVocabProgress(
                user_id=user.id,
                vocab_id=vocabulary.id,
                ease_factor=2.5,
            )
            db.add(progress)
            seeded_count += 1

        progress.interval = template["interval"]
        progress.repetitions = template["repetitions"]
        progress.ease_factor = 2.5
        progress.next_review_date = template["next_review_date"]

    return seeded_count


@app.get("/vocab/review", response_model=list[VocabReviewItem])
def get_vocab_review(
    limit: int = 30,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[VocabReviewItem]:
    now = datetime.utcnow()
    rows = db.execute(
        select(UserVocabProgress, Vocabulary)
        .join(Vocabulary, Vocabulary.id == UserVocabProgress.vocab_id)
        .where(
            UserVocabProgress.user_id == current_user.id,
            UserVocabProgress.next_review_date <= now,
        )
        .order_by(UserVocabProgress.next_review_date.asc())
        .limit(limit)
    ).all()

    return [
        VocabReviewItem(
            vocab_id=vocabulary.id,
            word=vocabulary.word,
            definition=vocabulary.definition,
            part_of_speech=vocabulary.part_of_speech,
            gsat_level=vocabulary.gsat_level,
            gsat_frequency=vocabulary.gsat_frequency,
            source_context=vocabulary.source_context,
            progress_id=progress.id,
            interval=progress.interval,
            repetitions=progress.repetitions,
            ease_factor=progress.ease_factor,
            next_review_date=progress.next_review_date,
        )
        for progress, vocabulary in rows
    ]


@app.post("/generate/vocab-mnemonic", response_model=VocabMnemonicResponse)
async def generate_vocab_mnemonic(
    request: VocabMnemonicRequest,
    current_user: User = Depends(check_ai_quota),
) -> VocabMnemonicResponse:
    word = request.word.strip()
    if not word:
        raise HTTPException(status_code=422, detail="word cannot be empty.")

    prompt = (
        "Create a vocabulary memory aid for a Taiwanese high school student preparing "
        "for the English GSAT. Return ONLY valid JSON with keys: etymology and "
        "taiwanese_mnemonic. etymology should explain roots, prefixes, suffixes, or "
        "word history in clear language. taiwanese_mnemonic should be a funny, Gen-Z "
        "Taiwanese Mandarin phonetic hook that helps remember the English meaning. "
        "Keep it classroom-safe and memorable.\n\n"
        f"Word: {word}\n"
        f"Definition: {request.definition or 'unknown'}\n"
        f"Source context: {request.source_context or ''}"
    )
    raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    parsed = parse_json_object_from_text(raw_response)
    return VocabMnemonicResponse(
        word=word,
        etymology=_safe_string(
            parsed.get("etymology"),
            f"Study the word parts and notice how {word} is used in context.",
        ),
        taiwanese_mnemonic=_safe_string(
            parsed.get("taiwanese_mnemonic"),
            f"把 {word} 跟你自己的生活畫面連起來，越荒謬越好記。",
        ),
        performance_metrics=metrics,
    )


@app.post("/vocab/update_progress", response_model=VocabUpdateProgressResponse)
def update_vocab_progress(
    request: VocabUpdateProgressRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> VocabUpdateProgressResponse:
    if request.action_id:
        receipt = db.scalar(
            select(ReviewSyncReceipt).where(
                ReviewSyncReceipt.action_id == request.action_id
            )
        )
        if receipt is not None:
            if receipt.user_id != current_user.id:
                raise HTTPException(status_code=409, detail="Sync action belongs to another user.")
            return VocabUpdateProgressResponse.model_validate_json(receipt.response_json)

    progress = db.scalar(
        select(UserVocabProgress).where(
            UserVocabProgress.user_id == current_user.id,
            UserVocabProgress.vocab_id == request.vocab_id,
        )
    )
    if progress is None:
        raise HTTPException(status_code=404, detail="Vocabulary progress not found.")

    try:
        updated = calculate_sm2(
            quality=request.quality,
            interval=progress.interval,
            repetitions=progress.repetitions,
            ease_factor=progress.ease_factor,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    progress.interval = updated["interval"]
    progress.repetitions = updated["repetitions"]
    progress.ease_factor = updated["ease_factor"]
    progress.next_review_date = updated["next_review_date"]
    progress.last_reviewed_at = datetime.utcnow()
    user = db.get(User, current_user.id)
    reward = None
    if user is not None:
        source_suffix = request.action_id or (
            f"progress:{progress.id}:{progress.last_reviewed_at.isoformat()}"
        )
        reward = record_learning_event(
            db,
            user=user,
            source_key=f"user:{user.id}:vocab-review:{source_suffix}",
            event_type="vocab_review",
            skill="vocab",
            outcome="recalled" if request.quality >= 3 else "effort_reviewed",
            points=10 if request.quality >= 5 else 8 if request.quality >= 3 else 5,
            message=(
                "這個單字已經更穩了。"
                if request.quality >= 3
                else "覺得困難也算有效學習，系統會更快安排它回來。"
            ),
            metadata={"vocab_id": progress.vocab_id, "quality": request.quality},
        )

    response = VocabUpdateProgressResponse(
        vocab_id=progress.vocab_id,
        user_id=progress.user_id,
        interval=progress.interval,
        repetitions=progress.repetitions,
        ease_factor=progress.ease_factor,
        next_review_date=progress.next_review_date,
        reward=reward,
    )
    if request.action_id:
        db.add(
            ReviewSyncReceipt(
                action_id=request.action_id,
                user_id=current_user.id,
                vocab_id=progress.vocab_id,
                response_json=response.model_dump_json(),
            )
        )
    db.commit()
    return response


@app.post("/grammar/error-ledger", response_model=GrammarLedgerSaveResponse)
def save_grammar_error(
    request: GrammarLedgerSaveRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> GrammarLedgerSaveResponse:
    entry = GrammarErrorLedger(
        user_id=current_user.id,
        error_type=request.error_type,
        original_sentence=request.original_sentence,
        user_answer=request.user_answer,
        corrected_sentence=request.corrected_sentence,
        explanation=request.explanation,
    )
    db.add(entry)
    db.commit()
    db.refresh(entry)

    return GrammarLedgerSaveResponse(
        id=entry.id,
        user_id=entry.user_id,
        error_type=entry.error_type,
        saved_at=entry.created_at,
    )


@app.get("/grammar/error-ledger", response_model=list[GrammarLedgerItem])
def get_grammar_error_ledger(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> list[GrammarLedgerItem]:
    entries = db.scalars(
        select(GrammarErrorLedger)
        .where(GrammarErrorLedger.user_id == current_user.id)
        .order_by(GrammarErrorLedger.is_mastered.asc(), GrammarErrorLedger.updated_at.desc())
    ).all()

    return [
        GrammarLedgerItem(
            id=entry.id,
            user_id=entry.user_id,
            error_type=entry.error_type,
            original_question=entry.original_sentence,
            user_answer=entry.user_answer,
            correct_answer=entry.corrected_sentence,
            explanation=entry.explanation,
            occurrence_count=entry.occurrence_count,
            is_mastered=bool(entry.is_mastered),
            created_at=entry.created_at,
            updated_at=entry.updated_at,
        )
        for entry in entries
    ]


@app.get("/daily-expansion-quiz", response_model=DailyExpansionQuizResponse)
def get_daily_expansion_quiz(
    limit: int = 15,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DailyExpansionQuizResponse:
    questions = list(
        db.scalars(
            select(DailyExpansionQuiz)
            .where(
                DailyExpansionQuiz.user_id == current_user.id,
                DailyExpansionQuiz.completed_at.is_(None),
                DailyExpansionQuiz.due_date <= datetime.utcnow(),
            )
            .order_by(DailyExpansionQuiz.due_date.asc(), DailyExpansionQuiz.id.asc())
            .limit(limit)
        ).all()
    )
    return DailyExpansionQuizResponse(
        required=bool(questions),
        due_count=len(questions),
        questions=[daily_expansion_item_to_response(item) for item in questions],
    )


@app.post("/daily-expansion-quiz/submit", response_model=DailyExpansionQuizSubmitResponse)
def submit_daily_expansion_quiz(
    request: DailyExpansionQuizSubmitRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> DailyExpansionQuizSubmitResponse:
    if not request.answers:
        raise HTTPException(status_code=422, detail="Submit at least one answer.")

    ids = [int(question_id) for question_id in request.answers.keys()]
    questions = list(
        db.scalars(
            select(DailyExpansionQuiz).where(
                DailyExpansionQuiz.user_id == current_user.id,
                DailyExpansionQuiz.id.in_(ids),
                DailyExpansionQuiz.completed_at.is_(None),
                DailyExpansionQuiz.due_date <= datetime.utcnow(),
            )
        ).all()
    )
    if not questions:
        raise HTTPException(status_code=404, detail="No due expansion questions found.")

    correct = 0
    completed_at = datetime.utcnow()
    for question in questions:
        selected = _safe_int(request.answers.get(question.id), -1)
        if selected == question.correct_option_index:
            correct += 1
        question.completed_at = completed_at

    db.commit()
    return DailyExpansionQuizSubmitResponse(
        completed=len(questions),
        correct=correct,
        total=len(questions),
    )


@app.post(
    "/grammar/error-ledger/{entry_id}/mastered",
    response_model=GrammarLedgerMasteredResponse,
)
def mark_grammar_error_mastered(
    entry_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
) -> GrammarLedgerMasteredResponse:
    entry = db.get(GrammarErrorLedger, entry_id)
    if entry is None or entry.user_id != current_user.id:
        raise HTTPException(status_code=404, detail="Grammar ledger entry not found.")

    entry.is_mastered = True
    entry.updated_at = datetime.utcnow()
    db.commit()
    db.refresh(entry)

    return GrammarLedgerMasteredResponse(id=entry.id, is_mastered=bool(entry.is_mastered))


@app.post("/generate/grammar/redemption", response_model=GrammarRedemptionResponse)
async def generate_grammar_redemption(
    request: GrammarRedemptionRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> GrammarRedemptionResponse:
    top_concepts = db.execute(
        select(
            GrammarErrorLedger.error_type,
            func.count(GrammarErrorLedger.id).label("failures"),
        )
        .where(
            GrammarErrorLedger.user_id == current_user.id,
            GrammarErrorLedger.is_mastered.is_(False),
        )
        .group_by(GrammarErrorLedger.error_type)
        .order_by(func.count(GrammarErrorLedger.id).desc())
        .limit(3)
    ).all()
    concepts = [str(row[0]) for row in top_concepts if row[0]]

    if not concepts:
        raise HTTPException(
            status_code=404,
            detail="No unmastered grammar errors are available for redemption.",
        )

    examples = db.scalars(
        select(GrammarErrorLedger)
        .where(
            GrammarErrorLedger.user_id == current_user.id,
            GrammarErrorLedger.error_type.in_(concepts),
            GrammarErrorLedger.is_mastered.is_(False),
        )
        .order_by(GrammarErrorLedger.updated_at.desc())
        .limit(9)
    ).all()

    concept_to_ids: dict[str, list[int]] = {concept: [] for concept in concepts}
    example_lines: list[str] = []
    for entry in examples:
        concept_to_ids.setdefault(entry.error_type, []).append(entry.id)
        example_lines.append(
            "- "
            f"id={entry.id}; concept={entry.error_type}; "
            f"question={entry.original_sentence}; "
            f"student_answer={entry.user_answer or 'unknown'}; "
            f"correct_answer={entry.corrected_sentence or 'unknown'}; "
            f"explanation={entry.explanation or 'none'}"
        )

    prompt = (
        "Use the student's top failed grammar concepts to create a redemption "
        "mini-quiz. Generate exactly 3 brand new GSAT-style multiple-choice "
        "questions targeting exactly these weaknesses. Return ONLY a JSON object "
        "with this shape: "
        '{"questions":[{"concept":"...","question":"...","options":["...","...","...","..."],'
        '"correct_option_index":0,"explanation":"...","ledger_error_ids":[1]}]}. '
        "Each options array must contain exactly 4 strings and correct_option_index "
        "must be zero-based.\n\n"
        f"Top failed concepts: {', '.join(concepts)}\n\n"
        "Saved error examples:\n"
        f"{chr(10).join(example_lines)}"
    )

    raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    parsed = parse_json_object_from_text(raw_response)
    raw_questions = parsed.get("questions")
    if not isinstance(raw_questions, list):
        raw_questions = []

    questions: list[GrammarRedemptionQuestion] = []
    fallback_options = [
        "She has studied English for three years.",
        "She studied English since three years.",
        "She studies English from three years.",
        "She is study English for three years.",
    ]

    for index, raw_question in enumerate(raw_questions[:3]):
        item = raw_question if isinstance(raw_question, dict) else {}
        concept = _safe_string(
            item.get("concept"),
            concepts[index % len(concepts)],
        )
        options_value = item.get("options")
        options = (
            [str(option).strip() for option in options_value if str(option).strip()]
            if isinstance(options_value, list)
            else []
        )
        while len(options) < 4:
            options.append(fallback_options[len(options)])
        options = options[:4]
        correct_index = _safe_int(item.get("correct_option_index"))
        if correct_index < 0 or correct_index >= len(options):
            correct_index = 0

        ids_value = item.get("ledger_error_ids")
        ids = [
            _safe_int(value)
            for value in ids_value
            if _safe_int(value) > 0
        ] if isinstance(ids_value, list) else []
        valid_ids = {entry.id for entry in examples}
        ids = [entry_id for entry_id in ids if entry_id in valid_ids]
        if not ids:
            ids = concept_to_ids.get(concept, [])[:1]
        if not ids and examples:
            ids = [examples[min(index, len(examples) - 1)].id]

        questions.append(
            GrammarRedemptionQuestion(
                concept=concept,
                question=_safe_string(
                    item.get("question"),
                    "Choose the grammatically correct sentence.",
                ),
                options=options,
                correct_option_index=correct_index,
                explanation=_safe_string(
                    item.get("explanation"),
                    "Review the grammar rule, then compare each option carefully.",
                ),
                ledger_error_ids=ids,
            )
        )

    while len(questions) < 3:
        concept = concepts[len(questions) % len(concepts)]
        related_ids = concept_to_ids.get(concept, [])[:1]
        questions.append(
            GrammarRedemptionQuestion(
                concept=concept,
                question="Choose the sentence that best follows standard English grammar.",
                options=fallback_options,
                correct_option_index=0,
                explanation="The correct choice uses a natural tense pattern and avoids common learner errors.",
                ledger_error_ids=related_ids,
            )
        )

    return GrammarRedemptionResponse(
        questions=questions,
        performance_metrics=metrics,
    )


@app.post("/upload/exam/analyze-mistakes", response_model=ExamUploadResponse)
@app.post("/upload/exam", response_model=ExamUploadResponse)
async def upload_exam(
    background_tasks: BackgroundTasks,
    file: UploadFile | None = File(default=None),
    exam_image: UploadFile | None = File(default=None),
    app_mode: str = Form(default="engagement"),
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> ExamUploadResponse:
    upload = exam_image or file
    if upload is None:
        raise HTTPException(status_code=422, detail="No image file was uploaded.")

    image_bytes, image_content_type = await read_validated_image_upload(
        upload,
        label="Exam image",
    )

    extracted_text = extract_text_from_image(image_bytes)
    if not extracted_text:
        raise HTTPException(
            status_code=422,
            detail="No English text could be extracted from the image.",
        )

    system_prompt = (
        "You are a senior Taiwanese GSAT English teacher. Inspect the uploaded "
        "mock exam image and the OCR text. Identify questions the student got "
        "wrong by using visible markings, circled answers, corrections, answer "
        "choices, and any teacher annotations. If the image does not clearly show "
        "the student's selected answer, infer conservatively and explain uncertainty."
    )
    diagnostic_prompt = (
        "Return ONLY a JSON object with these exact keys:\n"
        "analysis: a concise 3-point summary for the student;\n"
        "corrected_mistakes: an array of mistakes. Each mistake must include "
        "original_question, student_wrong_answer, correct_answer, explanation, "
        "grammar_concept, vocab_word. Use null for grammar_concept or vocab_word "
        "when not applicable. The explanation must be detailed and step-by-step.\n\n"
        "OCR text extracted from the paper:\n"
        f"{extracted_text}"
    )
    raw_analysis, metrics = await call_codex_vision_api(
        system_prompt=system_prompt,
        text_prompt=diagnostic_prompt,
        images=[(image_bytes, image_content_type)],
        app_mode=app_mode,
    )
    parsed = parse_json_object_from_text(raw_analysis)
    analysis = _safe_string(
        parsed.get("analysis"),
        "1. The paper was scanned successfully. 2. Review the corrected mistakes below. "
        "3. New 舉一反三 questions have been prepared for tomorrow.",
    )
    raw_mistakes = parsed.get("corrected_mistakes")
    if not isinstance(raw_mistakes, list):
        raw_mistakes = parse_json_array_from_text(raw_analysis)

    corrected_mistakes: list[CorrectedMistake] = []
    expansion_payload: list[dict[str, Any]] = []
    for raw_mistake in raw_mistakes:
        if not isinstance(raw_mistake, dict):
            continue
        original_question = _safe_string(
            raw_mistake.get("original_question") or raw_mistake.get("question"),
            "Question extracted from scanned exam",
        )
        wrong_answer = _safe_string(
            raw_mistake.get("student_wrong_answer")
            or raw_mistake.get("wrong_answer")
            or raw_mistake.get("student_answer"),
            "Unknown",
        )
        correct_answer = _safe_string(
            raw_mistake.get("correct_answer"),
            "Review the teacher explanation.",
        )
        explanation = _safe_string(
            raw_mistake.get("explanation"),
            "Review the target concept and compare the selected answer with the correct one.",
        )
        grammar_concept = _safe_string(raw_mistake.get("grammar_concept"), "")
        vocab_word = _safe_string(raw_mistake.get("vocab_word"), "")
        concept = normalize_concept(grammar_concept or vocab_word or "exam_mistake")

        ledger_entry = GrammarErrorLedger(
            user_id=current_user.id,
            error_type=concept,
            original_sentence=original_question,
            user_answer=wrong_answer,
            corrected_sentence=correct_answer,
            explanation=explanation,
        )
        db.add(ledger_entry)
        db.flush()

        vocab_id = upsert_vocab_progress_from_mistake(
            db,
            user_id=current_user.id,
            vocab_word=vocab_word,
            explanation=explanation,
            source_context=original_question,
        )

        expansion_payload.append(
            {
                "ledger_error_id": ledger_entry.id,
                "concept": concept,
                "original_question": original_question,
                "wrong_answer": wrong_answer,
                "correct_answer": correct_answer,
                "explanation": explanation,
            }
        )

        corrected_mistakes.append(
            CorrectedMistake(
                original_question=original_question,
                student_wrong_answer=wrong_answer,
                correct_answer=correct_answer,
                explanation=explanation,
                grammar_concept=grammar_concept or None,
                vocab_word=vocab_word or None,
                ledger_error_id=ledger_entry.id,
                vocab_id=vocab_id,
            )
        )

    db.commit()
    expansion_job: BackgroundJob | None = None
    if expansion_payload:
        ledger_ids = sorted(item["ledger_error_id"] for item in expansion_payload)
        idempotency_key = build_ai_cache_hash(
            {"type": "ocr_expansion", "user_id": current_user.id, "ledger_ids": ledger_ids}
        )
        expansion_job = db.scalar(
            select(BackgroundJob).where(BackgroundJob.idempotency_key == idempotency_key)
        )
        if expansion_job is None:
            expansion_job = BackgroundJob(
                id=secrets.token_hex(16),
                user_id=current_user.id,
                job_type="ocr_expansion",
                status="queued",
                payload_json=json.dumps(
                    {"mistakes": expansion_payload, "app_mode": app_mode},
                    ensure_ascii=False,
                ),
                idempotency_key=idempotency_key,
            )
            db.add(expansion_job)
            db.commit()
            db.refresh(expansion_job)
        if expansion_job.status in {"queued", "failed"} and int(expansion_job.attempts or 0) < 3:
            background_tasks.add_task(run_expansion_job, expansion_job.id)

    return ExamUploadResponse(
        extracted_text=extracted_text,
        analysis=analysis,
        corrected_mistakes=corrected_mistakes,
        expansion_quiz_count=0,
        expansion_job_id=expansion_job.id if expansion_job else None,
        expansion_job_status=expansion_job.status if expansion_job else None,
        performance_metrics=metrics,
    )


@app.post("/generate/grammar", response_model=GrammarResponse)
async def generate_grammar(
    request: GrammarRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> GrammarResponse:
    endpoint = "/generate/grammar"
    mode = request.mode.lower()
    gsat_references = fetch_gsat_few_shot_examples(db, "Grammar", limit=2)
    reference_signature = gsat_reference_signature(gsat_references)
    cache_params = {
        "mode": mode,
        "sentence": request.sentence,
        "app_mode": normalize_app_mode(request.app_mode),
        "ai_runtime": ai_runtime_signature(),
    }
    if reference_signature:
        cache_params["gsat_reference_signature"] = reference_signature
    cached_data = get_cached_ai_response(db, endpoint, cache_params)
    if cached_data is not None:
        cached_response = GrammarResponse(**cached_data)
        if mode != "quiz":
            ledger_entry = GrammarErrorLedger(
                user_id=current_user.id,
                error_type="general",
                original_sentence=request.sentence,
                corrected_sentence=cached_response.correction,
                explanation=cached_response.correction,
            )
            db.add(ledger_entry)
            db.commit()
        return cached_response

    if request.mode.lower() == "quiz":
        few_shot_prompt = build_gsat_few_shot_prompt("Grammar", gsat_references)
        prompt = (
            f"{few_shot_prompt}\n\n"
            "Create one GSAT-style English grammar multiple-choice question for "
            "a Taiwanese high school student. Return ONLY a JSON object with "
            "these exact keys: concept, question, options, correct_option_index, explanation. "
            "The concept should be a short snake_case grammar weakness label such as "
            "present_perfect, subject_verb_agreement, relative_clause, or verb_tense. "
            "The options value must be an array of exactly 4 strings. "
            "correct_option_index must be a zero-based integer. "
            "The explanation should teach the grammar concept clearly in 2-3 sentences.\n\n"
            f"Extra guidance: {request.sentence}"
        )

        raw_response, metrics = await call_preferred_text_ai(
            prompt,
            app_mode=request.app_mode,
        )
        quiz_data = parse_json_object_from_text(raw_response)
        options_value = quiz_data.get("options")
        options = (
            [str(option).strip() for option in options_value if str(option).strip()]
            if isinstance(options_value, list)
            else []
        )
        fallback_options = [
            "She has studied English for three years.",
            "She studied English since three years.",
            "She studies English from three years.",
            "She is study English for three years.",
        ]
        while len(options) < 4:
            options.append(fallback_options[len(options)])
        options = options[:4]
        correct_index = _safe_int(quiz_data.get("correct_option_index"))
        if correct_index < 0 or correct_index >= len(options):
            correct_index = 0

        question = _safe_string(
            quiz_data.get("question"),
            "Choose the grammatically correct sentence.",
        )
        explanation = _safe_string(
            quiz_data.get("explanation"),
            "Use the present perfect with 'for' to describe an action that started in the past and continues now.",
        )
        concept = _safe_string(quiz_data.get("concept"), "grammar_quiz")

        response_model = GrammarResponse(
            correction=explanation,
            concept=concept,
            question=question,
            options=options,
            correct_option_index=correct_index,
            explanation=explanation,
            performance_metrics=metrics,
        )
        save_ai_response_cache(db, endpoint, cache_params, response_model)
        return response_model

    few_shot_prompt = build_gsat_few_shot_prompt("Grammar", gsat_references)
    prompt = (
        f"{few_shot_prompt}\n\n"
        "You are an English grammar coach for Taiwanese high school students. "
        "Correct the sentence, explain the key grammar issue briefly, and provide "
        "one improved version.\n\n"
        f"Sentence: {request.sentence}"
    )

    correction, metrics = await call_preferred_text_ai(
        prompt,
        app_mode=request.app_mode,
    )
    ledger_entry = GrammarErrorLedger(
        user_id=current_user.id,
        error_type="general",
        original_sentence=request.sentence,
        corrected_sentence=correction,
        explanation=correction,
    )
    db.add(ledger_entry)
    db.commit()

    response_model = GrammarResponse(
        correction=correction,
        performance_metrics=metrics,
    )
    save_ai_response_cache(db, endpoint, cache_params, response_model)
    return response_model


@app.post("/evaluate/writing", response_model=WritingResponse)
async def evaluate_writing(
    request: Request,
    current_user: User = Depends(check_ai_quota),
) -> WritingResponse:
    content_type = request.headers.get("content-type", "").lower()
    essay_text = ""
    essay_type = "standard"
    app_mode = "engagement"
    prompt_image_bytes: bytes | None = None
    prompt_image_content_type = ""

    if content_type.startswith("multipart/form-data"):
        form = await request.form()
        essay_text = str(form.get("essay") or "").strip()
        essay_type = str(form.get("essay_type") or "standard").strip() or "standard"
        app_mode = str(form.get("app_mode") or "engagement").strip() or "engagement"

        handwritten_upload = (
            form.get("handwritten_essay")
            or form.get("essay_image")
            or form.get("file")
        )
        if handwritten_upload is not None and hasattr(handwritten_upload, "read"):
            handwritten_bytes, _ = await read_validated_image_upload(
                handwritten_upload,
                label="Handwritten essay image",
            )
            if handwritten_bytes:
                ocr_text = extract_text_from_image(handwritten_bytes)
                if ocr_text:
                    essay_text = f"{essay_text}\n\n[OCR handwritten essay]\n{ocr_text}".strip()

        prompt_upload = form.get("prompt_image")
        if prompt_upload is not None and hasattr(prompt_upload, "read"):
            prompt_image_bytes, prompt_image_content_type = await read_validated_image_upload(
                prompt_upload,
                label="Writing prompt image",
            )
    else:
        try:
            payload = await request.json()
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=422, detail="Invalid JSON body.") from exc
        if not isinstance(payload, dict):
            raise HTTPException(status_code=422, detail="JSON body must be an object.")
        try:
            parsed = WritingRequest(**payload)
        except ValidationError as exc:
            raise HTTPException(status_code=422, detail=exc.errors()) from exc
        essay_text = parsed.essay.strip()
        essay_type = parsed.essay_type.strip() or "standard"
        app_mode = parsed.app_mode

    with SessionLocal() as db:
        user = db.get(User, current_user.id)
        if user is None:
            raise HTTPException(status_code=401, detail="Token user no longer exists.")

    if not essay_text:
        raise HTTPException(
            status_code=422,
            detail="Provide typed essay text or a readable handwritten essay image.",
        )

    type_labels = {
        "standard": "Standard GSAT essay",
        "picture_description": "Picture Description (看圖說故事)",
        "chart_analysis": "Chart Analysis (圖表分析)",
    }
    type_label = type_labels.get(essay_type, essay_type)
    prompt_fit_instruction = (
        "Grade how accurately and completely the essay describes the provided "
        "picture or chart, including relevant details, logical sequencing, data "
        "interpretation when applicable, and avoiding unsupported claims. Balance "
        "this prompt-image relevance with grammar, vocabulary, organization, and "
        "GSAT scoring expectations."
        if prompt_image_bytes
        else "Grade content, grammar, vocabulary, organization, and GSAT relevance."
    )
    grading_prompt = (
        f"Essay type: {type_label}\n\n"
        f"{prompt_fit_instruction}\n\n"
        "Return ONLY a valid JSON object matching this contract: "
        "total_score (0-20), max_score (20), scores {content, organization, grammar, vocabulary; each 0-5}, "
        "spelling_and_punctuation_issues (array), corrections (array), strengths (array of strings), "
        "priority_improvements (array of strings), suggested_template (array of outline steps), "
        "advanced_vocabulary_alternatives (array), demonstration (string), rubric_version. "
        "Every issue/correction object must contain category, start_index, end_index, error_text, "
        "original_sentence, corrected_sentence, reason. Indexes refer to the unchanged student essay; "
        "use null when a reliable exact index is unavailable. Every vocabulary alternative must contain "
        "original, advanced, usage_note. total_score must equal the four score components. "
        "The demonstration is a short reference paragraph and must not replace or silently rewrite the "
        "student's original essay. Use rubric_version 'gsat-writing-v1'. No markdown fences.\n\n"
        f"Student essay:\n{essay_text}"
    )

    system_prompt = (
        "You are a strict Taiwanese GSAT English writing examiner. Preserve the student's original "
        "text, apply the supplied rubric consistently, and return schema-compliant JSON only. "
        "For picture or chart tasks, grade factual coverage and relevance to the supplied image."
    )
    evaluation: WritingEvaluation | None = None
    metrics: PerformanceMetrics | None = None
    validation_error = ""
    for attempt in range(2):
        attempt_prompt = grading_prompt
        if attempt:
            attempt_prompt = (
                f"{grading_prompt}\n\nYour previous response failed schema validation: "
                f"{validation_error}. Return corrected JSON only."
            )
        if prompt_image_bytes:
            raw_evaluation, attempt_metrics = await call_codex_vision_api(
                system_prompt=system_prompt,
                text_prompt=attempt_prompt,
                images=[(prompt_image_bytes, prompt_image_content_type)],
                app_mode=app_mode,
            )
        else:
            raw_evaluation, attempt_metrics = await call_codex_api(
                f"{system_prompt}\n\n{attempt_prompt}",
                app_mode=app_mode,
            )
        try:
            evaluation = parse_writing_evaluation(raw_evaluation)
            metrics = attempt_metrics
            break
        except (ValidationError, ValueError) as exc:
            validation_error = _clip_text(str(exc), 1200)

    if evaluation is None or metrics is None:
        raise HTTPException(
            status_code=502,
            detail=f"AI writing response failed schema validation: {validation_error}",
        )

    feedback_parts = [*evaluation.strengths, *evaluation.priority_improvements]
    feedback = " ".join(feedback_parts).strip() or "Writing evaluation completed."

    with SessionLocal() as db:
        user = db.get(User, current_user.id)
        if user is None:
            raise HTTPException(status_code=401, detail="Token user no longer exists.")
        user.essays_written = (user.essays_written or 0) + 1
        user.grammar_score_total = (
            user.grammar_score_total or 0.0
        ) + evaluation.scores.grammar
        user.grammar_score_count = (user.grammar_score_count or 0) + 1
        user.skill_writing = round(
            min(1.0, max(float(user.skill_writing or 0.0), evaluation.total_score / 20)),
            2,
        )
        record = WritingEvaluationRecord(
            user_id=user.id,
            essay_type=essay_type,
            original_essay=essay_text,
            prompt_image_present=bool(prompt_image_bytes),
            evaluation_json=json.dumps(
                evaluation.model_dump(mode="json"), ensure_ascii=False
            ),
            rubric_version=evaluation.rubric_version,
        )
        db.add(record)
        db.commit()
        db.refresh(record)

    return WritingResponse(
        evaluation_id=record.id,
        evaluation=evaluation,
        feedback=feedback,
        performance_metrics=metrics,
    )


@app.post("/generate/full-mock-exam", response_model=FullMockExamResponse)
async def generate_full_mock_exam(
    request: FullMockExamRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> FullMockExamResponse:
    endpoint = "/generate/full-mock-exam"
    skill_profile = {
        "vocabulary": round(float(current_user.skill_vocabulary or 0.0), 2),
        "grammar": round(float(current_user.skill_grammar or 0.0), 2),
        "reading": round(float(current_user.skill_reading or 0.0), 2),
        "writing": round(float(current_user.skill_writing or 0.0), 2),
    }
    skill_values = list(skill_profile.values())
    level_bucket = round(sum(skill_values) / max(1, len(skill_values)), 1)
    cache_params = {
        "difficulty": request.difficulty,
        "version": request.version,
        "level_bucket": level_bucket,
        "app_mode": normalize_app_mode(request.app_mode),
        "ai_runtime": ai_runtime_signature(),
        "structure": "gsat_full_mock_1_56_plus_non_choice",
    }
    if not request.force_refresh:
        cached_data = get_cached_ai_response(db, endpoint, cache_params)
        if cached_data is not None:
            cached_data.pop("exam_id", None)
            exam_id = secrets.token_hex(16)
            cached_response = FullMockExamResponse(exam_id=exam_id, **cached_data)
            db.add(
                MockExamSet(
                    id=exam_id,
                    user_id=current_user.id,
                    version=request.version,
                    difficulty=request.difficulty,
                    payload_json=model_to_cache_json(cached_response),
                )
            )
            db.commit()
            return sanitize_full_mock_exam_for_client(cached_response)

    few_shot_examples = {
        "grammar": gsat_reference_signature(fetch_gsat_few_shot_examples(db, "Grammar", limit=2)),
        "reading": gsat_reference_signature(fetch_gsat_few_shot_examples(db, "Reading", limit=2)),
        "discourse": gsat_reference_signature(fetch_gsat_few_shot_examples(db, "Discourse", limit=2)),
    }
    prompt = (
        "Generate a complete Taiwanese GSAT English mock exam set (模擬套題). "
        "Return ONLY one valid JSON object with keys: title, sections, non_choice. "
        "The sections array must contain exactly 6 objects:\n"
        "1 Vocabulary Questions 1-10, 2 Cloze Test 克漏字 Questions 11-20, "
        "3 Passage Completion 文意選填 Questions 21-30, 4 Discourse Structure 篇章結構 "
        "Questions 31-34, 5 Reading Comprehension 閱讀測驗 Questions 35-46, "
        "6 Mixed Question Types 混合題 Questions 47-56.\n"
        "Each section must include part, title, subtitle, instructions, optional passage/passages, "
        "and questions. Each multiple-choice question must include number, type, stem, options "
        "(exactly 4 strings), correct_option_index, and explanation. Number questions exactly "
        "1 through 56 with no gaps. non_choice must include translation and an essay prompt "
        "that clearly asks for a 120-word English composition. "
        "Difficulty should perfectly mirror Taiwan GSAT English: high school Level 5-6 vocabulary, "
        "authentic distractor logic, natural passages, and exam-ready formatting. "
        "Adapt the difficulty and scaffolding to the student's current radar skill profile "
        "while preserving authentic GSAT structure. "
        "Do not include markdown fences or commentary.\n\n"
        f"Difficulty: {request.difficulty}\n"
        f"Version seed: {request.version}\n"
        f"Student skill profile: {json.dumps(skill_profile, ensure_ascii=False)}\n"
        f"Reference signatures available for style calibration: {json.dumps(few_shot_examples)}"
    )

    try:
        raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
        parsed = parse_json_object_from_text(raw_response)
    except HTTPException:
        raise
    except Exception:
        parsed = {}
        metrics = PerformanceMetrics(
            total_time_seconds=0.0,
            tokens_per_second=0.0,
            total_tokens=0,
        )

    fallback = build_fallback_full_mock_exam()
    title = _safe_string(parsed.get("title"), fallback["title"])
    sections = parsed.get("sections")
    if not isinstance(sections, list) or len(sections) < 6:
        sections = fallback["sections"]
    non_choice = parsed.get("non_choice")
    if not isinstance(non_choice, dict):
        non_choice = fallback["non_choice"]

    exam_id = secrets.token_hex(16)
    response_model = FullMockExamResponse(
        exam_id=exam_id,
        title=title,
        generated_at=datetime.utcnow(),
        sections=sections,
        non_choice=non_choice,
        performance_metrics=metrics,
    )
    db.add(
        MockExamSet(
            id=exam_id,
            user_id=current_user.id,
            version=request.version,
            difficulty=request.difficulty,
            payload_json=model_to_cache_json(response_model),
        )
    )
    db.commit()
    save_ai_response_cache(db, endpoint, cache_params, response_model)
    return sanitize_full_mock_exam_for_client(response_model)


@app.post(
    "/generate/full-mock-exam/jobs",
    response_model=BackgroundJobResponse,
    status_code=202,
)
def queue_full_mock_exam(
    request: FullMockExamRequest,
    background_tasks: BackgroundTasks,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> BackgroundJobResponse:
    idempotency_key = build_ai_cache_hash(
        {
            "job_type": "full_mock_exam",
            "user_id": current_user.id,
            "difficulty": request.difficulty,
            "version": request.version,
            "app_mode": normalize_app_mode(request.app_mode),
        }
    )
    job = db.scalar(
        select(BackgroundJob).where(BackgroundJob.idempotency_key == idempotency_key)
    )
    if job is None:
        job = BackgroundJob(
            id=secrets.token_hex(16),
            user_id=current_user.id,
            job_type="full_mock_exam",
            status="queued",
            payload_json=request.model_dump_json(),
            idempotency_key=idempotency_key,
        )
        db.add(job)
        db.commit()
        db.refresh(job)
    if job.status in {"queued", "failed"} and int(job.attempts or 0) < 3:
        if job.status == "failed":
            job.status = "queued"
            job.error_message = None
            db.commit()
            db.refresh(job)
        schedule_background_job(background_tasks, job)
    return background_job_to_response(job)


@app.post(
    "/evaluate/full-mock-exam",
    response_model=FullMockExamEvaluationResponse,
)
async def evaluate_full_mock_exam(
    request: FullMockExamEvaluationRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> FullMockExamEvaluationResponse:
    exam = db.scalar(
        select(MockExamSet).where(
            MockExamSet.id == request.exam_id,
            MockExamSet.user_id == current_user.id,
        )
    )
    if exam is None:
        raise HTTPException(status_code=404, detail="Mock exam version was not found.")
    try:
        payload = json.loads(exam.payload_json)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=500, detail="Stored mock exam is corrupted.") from exc

    objective_total = 0
    objective_correct = 0
    section_scores: dict[str, dict[str, int]] = {}
    sections = payload.get("sections", []) if isinstance(payload, dict) else []
    for section in sections:
        if not isinstance(section, dict):
            continue
        section_name = _safe_string(section.get("title"), "Section")
        section_total = 0
        section_correct = 0
        for question in section.get("questions", []):
            if not isinstance(question, dict):
                continue
            number = _safe_int(question.get("number"), -1)
            correct_index = _safe_int(question.get("correct_option_index"), -1)
            if number < 1 or correct_index < 0:
                continue
            section_total += 1
            objective_total += 1
            if request.selected_answers.get(number) == correct_index:
                section_correct += 1
                objective_correct += 1
        section_scores[section_name] = {
            "correct": section_correct,
            "total": section_total,
        }
    if objective_total == 0:
        raise HTTPException(status_code=500, detail="Stored exam has no gradable questions.")
    objective_score = round((objective_correct / objective_total) * 70, 1)

    non_choice = payload.get("non_choice", {}) if isinstance(payload, dict) else {}
    translation_prompt = non_choice.get("translation", {}) if isinstance(non_choice, dict) else {}
    essay_prompt = non_choice.get("essay", {}) if isinstance(non_choice, dict) else {}
    grading_prompt = (
        "Grade the non-choice portion of a Taiwanese GSAT English mock exam. Return ONLY JSON with "
        "translation_score (0-10), essay_score (0-20), translation_feedback, essay_feedback, "
        "priority_improvements (array of strings), rubric_version ('gsat-mock-v1'). Be strict and "
        "do not award points for length alone. Translation must be accurate, grammatical, and complete. "
        "Essay scoring must consider content, organization, grammar, vocabulary, spelling, and relevance.\n\n"
        f"Translation prompt: {json.dumps(translation_prompt, ensure_ascii=False)}\n"
        f"Student translation (preserve exactly): {request.translation_answer}\n\n"
        f"Essay prompt: {json.dumps(essay_prompt, ensure_ascii=False)}\n"
        f"Student essay (preserve exactly): {request.essay_answer}"
    )
    subjective: FullMockExamSubjectiveEvaluation | None = None
    metrics: PerformanceMetrics | None = None
    validation_error = ""
    for attempt in range(2):
        prompt = grading_prompt
        if attempt:
            prompt += f"\n\nPrevious schema error: {validation_error}. Return corrected JSON only."
        raw, attempt_metrics = await call_codex_api(prompt, app_mode=request.app_mode)
        try:
            subjective = parse_mock_exam_subjective_evaluation(raw)
            metrics = attempt_metrics
            break
        except (ValidationError, ValueError) as exc:
            validation_error = _clip_text(str(exc), 1200)
    if subjective is None or metrics is None:
        raise HTTPException(
            status_code=502,
            detail=f"AI mock-exam grading failed schema validation: {validation_error}",
        )

    total_score = round(
        min(100.0, objective_score + subjective.translation_score + subjective.essay_score),
        1,
    )
    feedback = " ".join(
        [
            subjective.translation_feedback,
            subjective.essay_feedback,
            *subjective.priority_improvements,
        ]
    ).strip()
    attempt_id = secrets.token_hex(16)
    evaluation_payload = {
        "total_score": total_score,
        "objective_score": objective_score,
        "objective_correct": objective_correct,
        "objective_total": objective_total,
        "translation": subjective.model_dump(mode="json"),
        "section_scores": section_scores,
    }
    db.add(
        MockExamAttempt(
            id=attempt_id,
            exam_id=exam.id,
            user_id=current_user.id,
            answers_json=json.dumps(request.selected_answers, ensure_ascii=False),
            original_translation=request.translation_answer,
            original_essay=request.essay_answer,
            evaluation_json=json.dumps(evaluation_payload, ensure_ascii=False),
            rubric_version=subjective.rubric_version,
        )
    )
    db.commit()
    return FullMockExamEvaluationResponse(
        attempt_id=attempt_id,
        exam_id=exam.id,
        total_score=total_score,
        objective_score=objective_score,
        objective_correct=objective_correct,
        objective_total=objective_total,
        translation_score=subjective.translation_score,
        essay_score=subjective.essay_score,
        feedback=feedback,
        section_scores=section_scores,
        performance_metrics=metrics,
    )


@app.post("/generate/mixed-questions", response_model=MixedQuestionsResponse)
async def generate_mixed_questions(
    request: MixedQuestionRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> MixedQuestionsResponse:
    endpoint = "/generate/mixed-questions"
    cache_params = {
        "topic": request.topic,
        "difficulty": request.difficulty,
        "app_mode": normalize_app_mode(request.app_mode),
        "structure": "gsat_mixed_47_56_sandbox",
    }
    if not request.force_refresh:
        cached_data = get_cached_ai_response(db, endpoint, cache_params)
        if cached_data is not None:
            return MixedQuestionsResponse(**cached_data)

    prompt = (
        "Generate a Taiwanese GSAT English Mixed Question Types (混合題) sandbox "
        "for Questions 47-56. Return ONLY one valid JSON object with keys: "
        "text_a, text_b, multiple_choice, short_answer. Text A should be an "
        "article of about 200 English words. Text B should be a related chart "
        "description, memo, table summary, or notice of about 100 English words. "
        "multiple_choice must contain exactly 3 items with number, question, "
        "options (4 strings), correct_option_index, explanation. short_answer "
        "must contain exactly 2 items with number, question, reference_answer, "
        "max_score (2), rubric. Make the questions require integrating Text A "
        "and Text B, just like GSAT mixed questions 47-56. "
        f"Topic: {request.topic}. Difficulty: {request.difficulty}."
    )
    raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    parsed = parse_json_object_from_text(raw_response)
    fallback = build_fallback_mixed_questions()

    mcq_items = parsed.get("multiple_choice")
    short_items = parsed.get("short_answer")
    if not isinstance(mcq_items, list) or len(mcq_items) < 3:
        mcq_items = fallback["multiple_choice"]
    if not isinstance(short_items, list) or len(short_items) < 2:
        short_items = fallback["short_answer"]

    multiple_choice: list[MixedMultipleChoiceQuestion] = []
    for index, item in enumerate(mcq_items[:3], start=47):
        item = item if isinstance(item, dict) else {}
        options = safe_options(item.get("options"))
        correct_index = _safe_int(item.get("correct_option_index"))
        if correct_index < 0 or correct_index >= len(options):
            correct_index = 0
        multiple_choice.append(
            MixedMultipleChoiceQuestion(
                number=_safe_int(item.get("number"), index),
                question=_safe_string(item.get("question"), f"Mixed question {index}"),
                options=options,
                correct_option_index=correct_index,
                explanation=_safe_string(item.get("explanation"), "Use evidence from both texts."),
            )
        )

    short_answer: list[MixedShortAnswerQuestion] = []
    for index, item in enumerate(short_items[:2], start=50):
        item = item if isinstance(item, dict) else {}
        short_answer.append(
            MixedShortAnswerQuestion(
                number=_safe_int(item.get("number"), index),
                question=_safe_string(item.get("question"), f"Short answer {index}"),
                reference_answer=_safe_string(item.get("reference_answer"), "Use evidence from both texts."),
                max_score=max(1, min(2, _safe_int(item.get("max_score"), 2))),
                rubric=_safe_string(item.get("rubric"), "Award partial credit for accurate evidence and language."),
            )
        )

    response_model = MixedQuestionsResponse(
        text_a=_safe_string(parsed.get("text_a"), fallback["text_a"]),
        text_b=_safe_string(parsed.get("text_b"), fallback["text_b"]),
        multiple_choice=multiple_choice,
        short_answer=short_answer,
        performance_metrics=metrics,
    )
    save_ai_response_cache(db, endpoint, cache_params, response_model)
    return response_model


@app.post("/evaluate/mixed-answer", response_model=MixedAnswerEvaluationResponse)
async def evaluate_mixed_answer(
    request: MixedAnswerEvaluationRequest,
    current_user: User = Depends(check_ai_quota),
) -> MixedAnswerEvaluationResponse:
    max_score = max(1, min(2, request.max_score))
    prompt = (
        "Evaluate this Taiwanese GSAT English mixed-question short answer using "
        "partial credit. Return ONLY JSON with score, max_score, feedback. "
        "Score must be an integer from 0 to max_score. Give 1 point when the "
        "student identifies the right idea but has incomplete evidence or grammar. "
        f"Question: {request.question}\n"
        f"Reference answer: {request.reference_answer}\n"
        f"Rubric: {request.rubric or 'Use partial credit for meaning and language.'}\n"
        f"Student answer: {request.student_answer}\n"
        f"Max score: {max_score}"
    )
    raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    parsed = parse_json_object_from_text(raw_response)
    score = max(0, min(max_score, _safe_int(parsed.get("score"))))
    return MixedAnswerEvaluationResponse(
        score=score,
        max_score=max_score,
        feedback=_safe_string(
            parsed.get("feedback"),
            "Your answer was evaluated with partial credit for meaning, evidence, and grammar.",
        ),
        performance_metrics=metrics,
    )


@app.post("/evaluate/translation", response_model=TranslationEvaluationResponse)
async def evaluate_translation(
    request: TranslationEvaluationRequest,
    current_user: User = Depends(check_ai_quota),
) -> TranslationEvaluationResponse:
    chinese_sentence = request.chinese_sentence.strip()
    student_translation = request.student_translation.strip()
    if not chinese_sentence or not student_translation:
        raise HTTPException(
            status_code=422,
            detail="Provide both the Chinese sentence and the student's translation.",
        )

    prompt = (
        "You are a strict Taiwanese GSAT English examiner grading 中翻英. "
        "Base score is exactly 4.0 points for one sentence. Deduct 0.5 points "
        "for EACH spelling or punctuation error. Deduct 1.0 point for EACH "
        "grammar or sentence structure error. Do not be generous. Return ONLY "
        "valid JSON with keys: final_score, deductions, suggested_translation, "
        "grammar_concept. deductions must be an array where each item has "
        "error_text, error_type, points, explanation. error_text must be the "
        "exact word or phrase from the student's translation that should be "
        "highlighted red. final_score cannot be below 0 or above 4.\n\n"
        f"Chinese sentence: {chinese_sentence}\n"
        f"Student translation: {student_translation}\n"
        f"Target concept hint: {request.grammar_concept or 'infer from the sentence'}"
    )
    raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    parsed = parse_json_object_from_text(raw_response)
    raw_deductions = parsed.get("deductions")
    deductions: list[TranslationDeduction] = []
    if isinstance(raw_deductions, list):
        for item in raw_deductions:
            if not isinstance(item, dict):
                continue
            try:
                points = float(item.get("points") or 0)
            except (TypeError, ValueError):
                points = 0.0
            error_type = _safe_string(item.get("error_type"), "grammar")
            if points <= 0:
                points = 0.5 if error_type in {"spelling", "punctuation"} else 1.0
            deductions.append(
                TranslationDeduction(
                    error_text=_safe_string(item.get("error_text"), ""),
                    error_type=error_type,
                    points=round(points, 1),
                    explanation=_safe_string(item.get("explanation"), "Deduction applied."),
                )
            )

    calculated_score = 4.0 - sum(deduction.points for deduction in deductions)
    model_score = parsed.get("final_score")
    final_score = float(model_score) if isinstance(model_score, (int, float)) else calculated_score
    final_score = max(0.0, min(4.0, round(final_score, 1)))

    if not deductions and student_translation:
        # Trust a perfect score only when the model explicitly found no errors.
        final_score = max(0.0, min(4.0, final_score))

    return TranslationEvaluationResponse(
        final_score=final_score,
        deductions=deductions,
        suggested_translation=_safe_string(
            parsed.get("suggested_translation"),
            student_translation,
        ),
        grammar_concept=normalize_concept(
            _safe_string(parsed.get("grammar_concept"), request.grammar_concept or "translation"),
            fallback="translation",
        ),
        performance_metrics=metrics,
    )


@app.post("/generate/translation-similar", response_model=TranslationSimilarResponse)
async def generate_translation_similar(
    request: TranslationSimilarRequest,
    current_user: User = Depends(check_ai_quota),
) -> TranslationSimilarResponse:
    concept = normalize_concept(request.grammar_concept, fallback="translation")
    prompt = (
        "Generate one brand-new Chinese sentence for Taiwanese GSAT 中翻英 practice. "
        "It must test the exact same grammar concept, but use a different context "
        "and vocabulary. Return ONLY JSON with chinese_sentence and grammar_concept.\n\n"
        f"Grammar concept: {concept}\n"
        f"Previous source sentence: {request.source_sentence or ''}"
    )
    raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    parsed = parse_json_object_from_text(raw_response)
    return TranslationSimilarResponse(
        chinese_sentence=_safe_string(
            parsed.get("chinese_sentence"),
            "如果我們能善用時間，就能在考試前建立更多信心。",
        ),
        grammar_concept=normalize_concept(
            _safe_string(parsed.get("grammar_concept"), concept),
            fallback=concept,
        ),
        performance_metrics=metrics,
    )


@app.post("/generate/cloze-phrases", response_model=ClozePhrasesResponse)
async def generate_cloze_phrases(
    request: ClozePhrasesRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> ClozePhrasesResponse:
    endpoint = "/generate/cloze-phrases"
    selected_phrases = GSAT_HIGH_FREQUENCY_PHRASES[:10]
    cache_params = {
        "topic": request.topic,
        "phrases": selected_phrases,
        "app_mode": normalize_app_mode(request.app_mode),
        "structure": "gsat_phrase_collocation_cloze_10_blanks",
    }
    if not request.force_refresh:
        cached_data = get_cached_ai_response(db, endpoint, cache_params)
        if cached_data is not None:
            return ClozePhrasesResponse(**cached_data)

    prompt = (
        "Generate a Taiwanese GSAT 文意選填 practice item focused on high-frequency "
        "phrasal verbs and collocations. Use exactly these 10 phrases naturally "
        "inside one cohesive English story of about 150 words, then replace each "
        "phrase with [BLANK_1] through [BLANK_10]. Return ONLY JSON with keys: "
        "text, phrases, correct_mapping. phrases must be the 10 phrases shuffled. "
        "correct_mapping must map BLANK_1..BLANK_10 to the correct original phrase. "
        "Do not use markdown.\n\n"
        f"Topic: {request.topic}\n"
        f"Phrases: {json.dumps(selected_phrases, ensure_ascii=False)}"
    )
    raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    parsed = parse_json_object_from_text(raw_response)
    fallback = build_fallback_cloze_phrases()
    raw_phrases = parsed.get("phrases")
    phrases = (
        [str(phrase).strip() for phrase in raw_phrases if str(phrase).strip()]
        if isinstance(raw_phrases, list)
        else fallback["phrases"]
    )
    if len(phrases) < 10:
        phrases = fallback["phrases"]
    phrases = phrases[:10]
    mapping = parsed.get("correct_mapping")
    if not isinstance(mapping, dict) or len(mapping) < 10:
        mapping = fallback["correct_mapping"]
    mapping = {
        f"BLANK_{index}": _safe_string(mapping.get(f"BLANK_{index}"), fallback["correct_mapping"][f"BLANK_{index}"])
        for index in range(1, 11)
    }
    text_value = _safe_string(parsed.get("text"), fallback["text"])
    for index in range(1, 11):
        if f"[BLANK_{index}]" not in text_value:
            text_value = fallback["text"]
            break

    # Deterministic display shuffle without importing random: rotate by topic hash.
    shift = int(hashlib.sha256(request.topic.encode("utf-8")).hexdigest()[:2], 16) % len(phrases)
    shuffled_phrases = phrases[shift:] + phrases[:shift]
    response_model = ClozePhrasesResponse(
        text=text_value,
        phrases=shuffled_phrases,
        correct_mapping=mapping,
        performance_metrics=metrics,
    )
    save_ai_response_cache(db, endpoint, cache_params, response_model)
    return response_model


@app.post("/generate/sentence-upgrade", response_model=SentenceUpgradeGenerateResponse)
async def generate_sentence_upgrade(
    request: SentenceUpgradeGenerateRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> SentenceUpgradeGenerateResponse:
    endpoint = "/generate/sentence-upgrade"
    focus = request.focus or "rotating_gsat_advanced_structure"
    cache_params = {
        "focus": focus,
        "app_mode": normalize_app_mode(request.app_mode),
        "structure": "sentence_level_up_micro_training",
    }
    if not request.force_refresh:
        cached_data = get_cached_ai_response(db, endpoint, cache_params)
        if cached_data is not None:
            return SentenceUpgradeGenerateResponse(**cached_data)

    prompt = (
        "Create one Sentence Level-Up (句子升級) writing micro-drill for a Taiwanese "
        "GSAT English student. Return ONLY JSON with keys: basic_sentence, "
        "target_structure, instruction. The basic_sentence should be low-level "
        "English, usually two short simple sentences. The target_structure should "
        "be one advanced structure such as Participle Clause, Inversion, Relative "
        "Clause, Not only...but also, or It-cleft. The instruction should tell "
        "the student how to rewrite it without giving the answer.\n\n"
        f"Focus hint: {focus}"
    )
    raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    parsed = parse_json_object_from_text(raw_response)
    fallback = build_fallback_sentence_upgrade(request.focus)
    response_model = SentenceUpgradeGenerateResponse(
        basic_sentence=_safe_string(parsed.get("basic_sentence"), fallback["basic_sentence"]),
        target_structure=_safe_string(parsed.get("target_structure"), fallback["target_structure"]),
        instruction=_safe_string(parsed.get("instruction"), fallback["instruction"]),
        performance_metrics=metrics,
    )
    save_ai_response_cache(db, endpoint, cache_params, response_model)
    return response_model


@app.post("/evaluate/sentence-upgrade", response_model=SentenceUpgradeEvaluateResponse)
async def evaluate_sentence_upgrade(
    request: SentenceUpgradeEvaluateRequest,
    current_user: User = Depends(check_ai_quota),
) -> SentenceUpgradeEvaluateResponse:
    if not request.student_sentence.strip():
        raise HTTPException(status_code=422, detail="student_sentence cannot be empty.")

    prompt = (
        "You are a strict Taiwanese GSAT English writing coach. Evaluate whether "
        "the student's upgraded sentence successfully applies the requested "
        "advanced grammatical structure and remains grammatically correct. Return "
        "ONLY JSON with keys: passed (boolean), feedback, suggested_upgrade, "
        "detected_structure. passed should be true only if the target structure "
        "is clearly and correctly used without grammar errors.\n\n"
        f"Basic sentence: {request.basic_sentence}\n"
        f"Target structure: {request.target_structure}\n"
        f"Student rewrite: {request.student_sentence}"
    )
    raw_response, metrics = await call_codex_api(prompt, app_mode=request.app_mode)
    parsed = parse_json_object_from_text(raw_response)
    passed_value = parsed.get("passed")
    if isinstance(passed_value, bool):
        passed = passed_value
    elif isinstance(passed_value, str):
        passed = passed_value.strip().lower() in {"true", "yes", "pass", "passed"}
    else:
        passed = False

    return SentenceUpgradeEvaluateResponse(
        passed=passed,
        feedback=_safe_string(
            parsed.get("feedback"),
            "Check whether the target structure is clearly used and grammatically correct.",
        ),
        suggested_upgrade=_safe_string(
            parsed.get("suggested_upgrade"),
            request.student_sentence,
        ),
        detected_structure=_safe_string(
            parsed.get("detected_structure"),
            request.target_structure,
        ),
        performance_metrics=metrics,
    )


@app.post("/generate/reading", response_model=ReadingResponse)
async def generate_reading(
    request: ReadingRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> ReadingResponse:
    endpoint = "/generate/reading"
    gsat_references = fetch_gsat_few_shot_examples(db, "Reading", limit=2)
    reference_signature = gsat_reference_signature(gsat_references)
    cache_params = {
        "topic": request.topic,
        "level": request.level,
        "word_count": request.word_count,
        "app_mode": normalize_app_mode(request.app_mode),
        "ai_runtime": ai_runtime_signature(),
    }
    if reference_signature:
        cache_params["gsat_reference_signature"] = reference_signature
    cached_data = get_cached_ai_response(db, endpoint, cache_params)
    if cached_data is not None:
        return ReadingResponse(**cached_data)

    few_shot_prompt = build_gsat_few_shot_prompt("Reading", gsat_references)
    prompt = (
        f"{few_shot_prompt}\n\n"
        "Write an English news-style reading passage for Taiwanese high school "
        "students preparing for the GSAT. Keep the language natural, include "
        "useful academic vocabulary, and avoid bullet points.\n\n"
        f"Topic: {request.topic}\n"
        f"Level: {request.level}\n"
        f"Approximate word count: {request.word_count}"
    )

    article, metrics = await call_preferred_text_ai(
        prompt,
        app_mode=request.app_mode,
    )
    response_model = ReadingResponse(
        article=article,
        performance_metrics=metrics,
    )
    save_ai_response_cache(db, endpoint, cache_params, response_model)
    return response_model


@app.post("/generate/discourse", response_model=DiscourseResponse)
async def generate_discourse(
    request: Request,
    db: Session = Depends(get_db),
    current_user: User = Depends(check_ai_quota),
) -> DiscourseResponse:
    app_mode = "engagement"
    try:
        payload = await request.json()
        if isinstance(payload, dict):
            app_mode = str(payload.get("app_mode") or "engagement")
    except Exception:
        pass

    gsat_references = fetch_gsat_few_shot_examples(db, "Discourse", limit=2)
    few_shot_prompt = build_gsat_few_shot_prompt("Discourse", gsat_references)
    prompt = (
        f"{few_shot_prompt}\n\n"
        "Create one Taiwanese GSAT English Discourse Structure (篇章結構) "
        "drag-and-drop question. Generate a cohesive 4-paragraph English article "
        "at high-school GSAT level. Extract exactly 4 key sentences from the article, "
        "replace those sentences in the article with markers [BLANK_1], [BLANK_2], "
        "[BLANK_3], and [BLANK_4], then return ONLY a JSON object with these exact "
        "keys: article_with_blanks, extracted_sentences, correct_mapping. "
        "article_with_blanks must contain all four blank markers. extracted_sentences "
        "must be a shuffled array of exactly 4 sentence strings. correct_mapping must "
        "map BLANK_1, BLANK_2, BLANK_3, BLANK_4 to the exact original sentence strings. "
        "Do not include markdown or explanations."
    )

    raw_response, metrics = await call_preferred_text_ai(
        prompt,
        app_mode=app_mode,
    )
    parsed = parse_json_object_from_text(raw_response)
    article = _safe_string(parsed.get("article_with_blanks"), "")
    extracted_value = parsed.get("extracted_sentences")
    extracted_sentences = (
        [str(sentence).strip() for sentence in extracted_value if str(sentence).strip()]
        if isinstance(extracted_value, list)
        else []
    )
    mapping_value = parsed.get("correct_mapping")
    correct_mapping = (
        {
            str(key).strip().replace("[", "").replace("]", ""): str(value).strip()
            for key, value in mapping_value.items()
        }
        if isinstance(mapping_value, dict)
        else {}
    )

    blanks = [f"BLANK_{index}" for index in range(1, 5)]
    extracted_sentence_set = set(extracted_sentences)
    is_valid = (
        article
        and len(extracted_sentences) == 4
        and all(f"[{blank}]" in article for blank in blanks)
        and all(blank in correct_mapping for blank in blanks)
        and all(correct_mapping[blank] for blank in blanks)
        and all(correct_mapping[blank] in extracted_sentence_set for blank in blanks)
    )

    if not is_valid:
        article = (
            "Many students believe that preparing for an English exam requires only "
            "memorizing long vocabulary lists. [BLANK_1]\n\n"
            "A better approach is to meet words in meaningful situations. [BLANK_2]\n\n"
            "Writing practice is equally important because it reveals problems that "
            "multiple-choice questions may hide. [BLANK_3]\n\n"
            "For this reason, successful learners usually build small routines they can "
            "repeat every day. [BLANK_4]"
        )
        correct_mapping = {
            "BLANK_1": "However, real progress often comes from connecting new words with clear contexts.",
            "BLANK_2": "When learners see a word in an article, they understand how it behaves naturally.",
            "BLANK_3": "By reviewing these mistakes, students can notice patterns and avoid repeating them.",
            "BLANK_4": "Over time, these habits turn exam preparation into steady and visible improvement.",
        }
        extracted_sentences = [
            correct_mapping["BLANK_3"],
            correct_mapping["BLANK_1"],
            correct_mapping["BLANK_4"],
            correct_mapping["BLANK_2"],
        ]
    else:
        correct_mapping = {blank: correct_mapping[blank] for blank in blanks}
        extracted_sentences = extracted_sentences[:4]
        secrets.SystemRandom().shuffle(extracted_sentences)

    return DiscourseResponse(
        article_with_blanks=article,
        extracted_sentences=extracted_sentences,
        correct_mapping=correct_mapping,
        performance_metrics=metrics,
    )
