from datetime import date, datetime

from sqlalchemy import (
    Column,
    Boolean,
    Date,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.orm import declarative_base, relationship


Base = declarative_base()


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    email = Column(String(255), unique=True, index=True, nullable=False)
    display_name = Column(String(120), nullable=True)
    password_hash = Column(String(255), nullable=True)
    essays_written = Column(Integer, default=0, nullable=False)
    grammar_score_total = Column(Float, default=0.0, nullable=False)
    grammar_score_count = Column(Integer, default=0, nullable=False)
    last_login_date = Column(DateTime, nullable=True)
    current_streak = Column(Integer, default=0, nullable=False)
    daily_ai_quota = Column(Integer, default=20, nullable=False)
    quota_reset_date = Column(DateTime, default=datetime.utcnow, nullable=False)
    is_pro = Column(Boolean, default=False, nullable=False)
    has_completed_onboarding = Column(Boolean, default=False, nullable=False)
    skill_vocabulary = Column(Float, default=0.0, nullable=False)
    skill_grammar = Column(Float, default=0.0, nullable=False)
    skill_reading = Column(Float, default=0.0, nullable=False)
    skill_writing = Column(Float, default=0.0, nullable=False)
    target_exam_date = Column(DateTime, nullable=True)
    is_admin = Column(Boolean, default=False, nullable=False)
    email_verified_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    vocab_progress = relationship(
        "UserVocabProgress",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    grammar_errors = relationship(
        "GrammarErrorLedger",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    daily_expansion_quizzes = relationship(
        "DailyExpansionQuiz",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    refresh_tokens = relationship(
        "RefreshToken",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    email_action_tokens = relationship(
        "EmailActionToken",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    daily_mission_tasks = relationship(
        "DailyMissionTask",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    review_sync_receipts = relationship(
        "ReviewSyncReceipt",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    background_jobs = relationship(
        "BackgroundJob",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    writing_evaluations = relationship(
        "WritingEvaluationRecord",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    mock_exam_sets = relationship(
        "MockExamSet",
        back_populates="user",
        cascade="all, delete-orphan",
    )
    mock_exam_attempts = relationship(
        "MockExamAttempt",
        back_populates="user",
        cascade="all, delete-orphan",
    )


class Vocabulary(Base):
    __tablename__ = "vocabulary"

    id = Column(Integer, primary_key=True, index=True)
    word = Column(String(120), unique=True, index=True, nullable=False)
    definition = Column(Text, nullable=True)
    part_of_speech = Column(String(40), nullable=True)
    gsat_level = Column(Integer, nullable=True, index=True)
    gsat_frequency = Column(Integer, nullable=True, index=True)
    source_context = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    progress = relationship(
        "UserVocabProgress",
        back_populates="vocabulary",
        cascade="all, delete-orphan",
    )


class UserVocabProgress(Base):
    __tablename__ = "user_vocab_progress"
    __table_args__ = (
        UniqueConstraint("user_id", "vocab_id", name="uq_user_vocab_progress"),
    )

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    vocab_id = Column(Integer, ForeignKey("vocabulary.id"), nullable=False, index=True)
    interval = Column(Integer, default=0, nullable=False)
    repetitions = Column(Integer, default=0, nullable=False)
    ease_factor = Column(Float, default=2.5, nullable=False)
    next_review_date = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)
    last_reviewed_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        nullable=False,
    )

    user = relationship("User", back_populates="vocab_progress")
    vocabulary = relationship("Vocabulary", back_populates="progress")


class GrammarErrorLedger(Base):
    __tablename__ = "grammar_error_ledger"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    error_type = Column(String(120), nullable=False, index=True)
    original_sentence = Column(Text, nullable=False)
    user_answer = Column(Text, nullable=True)
    corrected_sentence = Column(Text, nullable=True)
    explanation = Column(Text, nullable=True)
    is_mastered = Column(Boolean, default=False, nullable=False, index=True)
    occurrence_count = Column(Integer, default=1, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        nullable=False,
    )

    user = relationship("User", back_populates="grammar_errors")


class GrammarConceptBank(Base):
    __tablename__ = "grammar_concept_bank"

    id = Column(Integer, primary_key=True, index=True)
    name = Column(String(120), unique=True, index=True, nullable=False)
    category = Column(String(120), nullable=True, index=True)
    description = Column(Text, nullable=True)
    example_sentence = Column(Text, nullable=True)
    gsat_level = Column(Integer, nullable=True, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)


class AICache(Base):
    __tablename__ = "ai_cache"

    id = Column(Integer, primary_key=True, index=True)
    prompt_hash = Column(String(64), index=True, nullable=False)
    endpoint = Column(String(120), index=True, nullable=False)
    response_json = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)


class GSATReferencePaper(Base):
    __tablename__ = "gsat_reference_papers"

    id = Column(Integer, primary_key=True, index=True)
    year = Column(Integer, nullable=False, index=True)
    exam_type = Column(String(40), nullable=False, index=True)
    content = Column(Text, nullable=False)
    json_structure = Column(Text, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)


class DailyExpansionQuiz(Base):
    __tablename__ = "daily_expansion_quizzes"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    grammar_error_id = Column(
        Integer,
        ForeignKey("grammar_error_ledger.id"),
        nullable=True,
        index=True,
    )
    concept = Column(String(120), nullable=False, index=True)
    question = Column(Text, nullable=False)
    options_json = Column(Text, nullable=False)
    correct_option_index = Column(Integer, default=0, nullable=False)
    explanation = Column(Text, nullable=True)
    source_job_id = Column(String(64), nullable=True, index=True)
    due_date = Column(DateTime, nullable=False, index=True)
    completed_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    user = relationship("User", back_populates="daily_expansion_quizzes")
    grammar_error = relationship("GrammarErrorLedger")


class RefreshToken(Base):
    __tablename__ = "refresh_tokens"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    token_hash = Column(String(64), unique=True, nullable=False, index=True)
    jti = Column(String(64), unique=True, nullable=False, index=True)
    expires_at = Column(DateTime, nullable=False, index=True)
    revoked_at = Column(DateTime, nullable=True, index=True)
    replaced_by_jti = Column(String(64), nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    user = relationship("User", back_populates="refresh_tokens")


class DailyMissionTask(Base):
    __tablename__ = "daily_mission_tasks"
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "mission_date",
            "task_key",
            name="uq_daily_mission_task",
        ),
    )

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    mission_date = Column(Date, default=date.today, nullable=False, index=True)
    task_key = Column(String(120), nullable=False)
    task_type = Column(String(80), nullable=False, index=True)
    count = Column(Integer, nullable=True)
    topic = Column(String(255), nullable=True)
    minutes = Column(Integer, nullable=True)
    priority = Column(String(20), default="core", nullable=False)
    status = Column(String(20), default="pending", nullable=False, index=True)
    completed_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        nullable=False,
    )

    user = relationship("User", back_populates="daily_mission_tasks")


class BackgroundJob(Base):
    __tablename__ = "background_jobs"

    id = Column(String(64), primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    job_type = Column(String(80), nullable=False, index=True)
    status = Column(String(20), default="queued", nullable=False, index=True)
    payload_json = Column(Text, nullable=False)
    result_json = Column(Text, nullable=True)
    error_message = Column(Text, nullable=True)
    attempts = Column(Integer, default=0, nullable=False)
    idempotency_key = Column(String(128), unique=True, nullable=False, index=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        nullable=False,
    )
    completed_at = Column(DateTime, nullable=True)

    user = relationship("User", back_populates="background_jobs")


class WritingEvaluationRecord(Base):
    __tablename__ = "writing_evaluations"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    essay_type = Column(String(80), nullable=False, index=True)
    original_essay = Column(Text, nullable=False)
    prompt_image_present = Column(Boolean, default=False, nullable=False)
    evaluation_json = Column(Text, nullable=False)
    rubric_version = Column(String(40), default="gsat-writing-v1", nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)

    user = relationship("User", back_populates="writing_evaluations")


class MockExamSet(Base):
    __tablename__ = "mock_exam_sets"

    id = Column(String(64), primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    version = Column(String(120), nullable=False, index=True)
    difficulty = Column(String(80), nullable=False)
    payload_json = Column(Text, nullable=False)
    rubric_version = Column(String(40), default="gsat-mock-v1", nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)

    user = relationship("User", back_populates="mock_exam_sets")
    attempts = relationship(
        "MockExamAttempt",
        back_populates="exam",
        cascade="all, delete-orphan",
    )


class MockExamAttempt(Base):
    __tablename__ = "mock_exam_attempts"

    id = Column(String(64), primary_key=True)
    exam_id = Column(String(64), ForeignKey("mock_exam_sets.id"), nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    answers_json = Column(Text, nullable=False)
    original_translation = Column(Text, nullable=True)
    original_essay = Column(Text, nullable=True)
    evaluation_json = Column(Text, nullable=False)
    rubric_version = Column(String(40), default="gsat-mock-v1", nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)

    exam = relationship("MockExamSet", back_populates="attempts")
    user = relationship("User", back_populates="mock_exam_attempts")


class EmailActionToken(Base):
    __tablename__ = "email_action_tokens"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    purpose = Column(String(40), nullable=False, index=True)
    token_hash = Column(String(64), unique=True, nullable=False, index=True)
    expires_at = Column(DateTime, nullable=False, index=True)
    used_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    user = relationship("User", back_populates="email_action_tokens")


class ReviewSyncReceipt(Base):
    __tablename__ = "review_sync_receipts"

    id = Column(Integer, primary_key=True, index=True)
    action_id = Column(String(128), unique=True, nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    vocab_id = Column(Integer, ForeignKey("vocabulary.id"), nullable=False, index=True)
    response_json = Column(Text, nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    user = relationship("User", back_populates="review_sync_receipts")
