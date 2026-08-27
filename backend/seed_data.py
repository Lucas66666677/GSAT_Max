"""Seed core GSAT English content into the configured database.

Usage examples:
    python seed_data.py --vocab 500
    python backend/seed_data.py --vocab 500 --grammar 50
    python backend/seed_data.py --vocab 100 --batch-size 25 --offline-fallback

The script uses the OpenAI-compatible Codex API configured by:
    OPENAI_API_KEY, OPENAI_BASE_URL, CODEX_MODEL / OPENAI_MODEL
"""

from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import sys
from typing import Any

import httpx
from alembic import command as alembic_command
from alembic.config import Config as AlembicConfig
from dotenv import load_dotenv
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker

CURRENT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = CURRENT_DIR.parent
load_dotenv(PROJECT_ROOT / ".env", override=False)
if str(CURRENT_DIR) not in sys.path:
    sys.path.insert(0, str(CURRENT_DIR))

from config import normalize_database_url  # noqa: E402
from models import GrammarConceptBank, Vocabulary  # noqa: E402


DEFAULT_DATABASE_URL = f"sqlite:///{(CURRENT_DIR / 'gsat_english.db').as_posix()}"
OPENAI_BASE_URL = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
CODEX_MODEL = os.getenv("CODEX_MODEL", os.getenv("OPENAI_MODEL", "gpt-4o-mini"))


FALLBACK_GRAMMAR_CONCEPTS: list[dict[str, Any]] = [
    {"name": "Inversion", "category": "sentence_structure", "description": "Negative adverbials or limiting expressions trigger auxiliary-subject inversion.", "example_sentence": "Never have I seen such a challenging article.", "gsat_level": 5},
    {"name": "Subjunctive Mood", "category": "verb_forms", "description": "Use base verbs after verbs such as suggest, demand, and insist.", "example_sentence": "The teacher suggested that he review the passage again.", "gsat_level": 5},
    {"name": "Participle Clauses", "category": "sentence_reduction", "description": "Reduce clauses with active or passive participles to make writing concise.", "example_sentence": "Walking into the classroom, Mia noticed the new schedule.", "gsat_level": 5},
    {"name": "Relative Clauses", "category": "modification", "description": "Use who, which, that, where, and whose to add precise information.", "example_sentence": "The article that we discussed yesterday appears on the exam.", "gsat_level": 4},
    {"name": "Reduced Relative Clauses", "category": "sentence_reduction", "description": "Omit relative pronouns and be-verbs when grammar allows reduction.", "example_sentence": "The students selected for the contest practiced daily.", "gsat_level": 5},
    {"name": "Present Perfect", "category": "tense", "description": "Connect past actions to the present with have or has plus past participle.", "example_sentence": "She has studied English for three years.", "gsat_level": 3},
    {"name": "Past Perfect", "category": "tense", "description": "Show that one past action happened before another past action.", "example_sentence": "He had finished the essay before the bell rang.", "gsat_level": 4},
    {"name": "Future Perfect", "category": "tense", "description": "Describe completion before a future time.", "example_sentence": "By next month, they will have completed the review plan.", "gsat_level": 5},
    {"name": "Subject-Verb Agreement", "category": "agreement", "description": "Match singular or plural subjects with correct verb forms.", "example_sentence": "Each of the students has a different goal.", "gsat_level": 3},
    {"name": "Pronoun Agreement", "category": "agreement", "description": "Make pronouns agree with antecedents in number and reference.", "example_sentence": "Every student should check his or her answer carefully.", "gsat_level": 3},
    {"name": "Gerunds and Infinitives", "category": "verb_patterns", "description": "Choose -ing forms or to-infinitives after specific verbs.", "example_sentence": "She avoided making the same mistake twice.", "gsat_level": 4},
    {"name": "Causative Verbs", "category": "verb_patterns", "description": "Use make, have, let, get, and help with correct object complements.", "example_sentence": "The coach had the team practice transitions.", "gsat_level": 4},
    {"name": "Conditional Sentences", "category": "logic", "description": "Use if-clauses to express real, unreal, or past unreal conditions.", "example_sentence": "If he had read the chart carefully, he would have answered correctly.", "gsat_level": 5},
    {"name": "Mixed Conditionals", "category": "logic", "description": "Combine time references across condition and result clauses.", "example_sentence": "If she had slept earlier, she would feel better now.", "gsat_level": 5},
    {"name": "Passive Voice", "category": "voice", "description": "Focus on the receiver of an action with be plus past participle.", "example_sentence": "The results were announced after the meeting.", "gsat_level": 3},
    {"name": "Modal Verbs", "category": "modality", "description": "Use can, should, must, may, and might to show ability, advice, duty, or possibility.", "example_sentence": "Students should review their mistakes before the next test.", "gsat_level": 3},
    {"name": "Modal Perfect", "category": "modality", "description": "Use modal plus have plus past participle for past deduction or criticism.", "example_sentence": "She must have misunderstood the question.", "gsat_level": 5},
    {"name": "Comparatives and Superlatives", "category": "comparison", "description": "Compare two or more people, things, or ideas accurately.", "example_sentence": "This method is more efficient than memorizing lists.", "gsat_level": 3},
    {"name": "Correlative Conjunctions", "category": "parallelism", "description": "Use pairs such as not only...but also and either...or with parallel grammar.", "example_sentence": "The plan improves not only vocabulary but also confidence.", "gsat_level": 4},
    {"name": "Parallel Structure", "category": "parallelism", "description": "Keep paired or listed ideas in the same grammatical form.", "example_sentence": "The app helps students read faster, write clearly, and review consistently.", "gsat_level": 4},
    {"name": "Appositives", "category": "modification", "description": "Rename a noun with a nearby noun phrase.", "example_sentence": "Ms. Lin, our English teacher, designed the quiz.", "gsat_level": 4},
    {"name": "Noun Clauses", "category": "clauses", "description": "Use clauses as subjects, objects, or complements.", "example_sentence": "What surprised me was the article's conclusion.", "gsat_level": 4},
    {"name": "Adverb Clauses", "category": "clauses", "description": "Use subordinators such as although, because, while, and unless.", "example_sentence": "Although the passage was long, the main idea was clear.", "gsat_level": 3},
    {"name": "Adjective Clauses", "category": "clauses", "description": "Modify nouns with relative clause structures.", "example_sentence": "The student who asked questions improved quickly.", "gsat_level": 3},
    {"name": "Emphatic Cleft Sentences", "category": "sentence_structure", "description": "Use it-cleft or what-cleft structures to emphasize information.", "example_sentence": "It was the final paragraph that confused most students.", "gsat_level": 5},
    {"name": "Transition Logic", "category": "discourse", "description": "Choose transitions that match contrast, cause, result, or addition.", "example_sentence": "The method is simple; however, it requires discipline.", "gsat_level": 4},
    {"name": "Reference Words", "category": "reading", "description": "Track pronouns and demonstratives back to their referents.", "example_sentence": "This refers to the habit described in the previous sentence.", "gsat_level": 4},
    {"name": "Dangling Modifiers", "category": "modification", "description": "Ensure introductory modifiers logically describe the subject that follows.", "example_sentence": "After reading the chart, the student revised her answer.", "gsat_level": 5},
    {"name": "Preposition Collocations", "category": "collocation", "description": "Use common adjective, noun, and verb-preposition combinations.", "example_sentence": "She is responsible for organizing the study group.", "gsat_level": 3},
    {"name": "Article Usage", "category": "determiners", "description": "Choose a, an, the, or zero article based on specificity and countability.", "example_sentence": "The article discusses a problem many students face.", "gsat_level": 3},
    {"name": "Countable and Uncountable Nouns", "category": "nouns", "description": "Use correct quantifiers and verb agreement with noun types.", "example_sentence": "The teacher gave us useful advice before the exam.", "gsat_level": 3},
    {"name": "Reported Speech", "category": "speech", "description": "Shift tense, pronouns, and time expressions when reporting statements.", "example_sentence": "He said that he had finished the practice test.", "gsat_level": 4},
    {"name": "Question Tags", "category": "sentence_structure", "description": "Attach short confirmation questions with correct auxiliary polarity.", "example_sentence": "You finished the worksheet, didn't you?", "gsat_level": 3},
    {"name": "Indirect Questions", "category": "sentence_structure", "description": "Use statement word order after question phrases in embedded questions.", "example_sentence": "Do you know why the answer is B?", "gsat_level": 4},
    {"name": "Wish Clauses", "category": "subjunctive", "description": "Use past or past perfect forms to express regret or unreal wishes.", "example_sentence": "I wish I had reviewed the vocabulary earlier.", "gsat_level": 5},
    {"name": "Purpose Clauses", "category": "logic", "description": "Use so that, in order to, and so as to to express purpose.", "example_sentence": "She reviewed daily so that she could remember more words.", "gsat_level": 3},
    {"name": "Result Clauses", "category": "logic", "description": "Use so...that and such...that to show results.", "example_sentence": "The passage was so complex that many students reread it.", "gsat_level": 4},
    {"name": "Concession", "category": "logic", "description": "Use although, even though, despite, and in spite of correctly.", "example_sentence": "Despite the pressure, he stayed calm.", "gsat_level": 4},
    {"name": "Partitive Expressions", "category": "nouns", "description": "Use phrases such as a number of, the number of, and a piece of.", "example_sentence": "The number of applicants has increased.", "gsat_level": 4},
    {"name": "Verb Tense Consistency", "category": "tense", "description": "Keep tense logical across sentences and time markers.", "example_sentence": "The writer explains the problem and then offers a solution.", "gsat_level": 3},
    {"name": "Phrasal Verbs", "category": "vocabulary_grammar", "description": "Understand verb-particle meanings and separability.", "example_sentence": "She came up with a better study plan.", "gsat_level": 4},
    {"name": "Collocation Choice", "category": "vocabulary_grammar", "description": "Choose natural word partners rather than direct translations.", "example_sentence": "Students should make progress, not do progress.", "gsat_level": 4},
    {"name": "Sentence Fragments", "category": "writing_errors", "description": "Avoid incomplete sentences lacking a main clause.", "example_sentence": "Because the test was difficult, many students reviewed again.", "gsat_level": 3},
    {"name": "Run-on Sentences", "category": "writing_errors", "description": "Separate or connect independent clauses correctly.", "example_sentence": "The passage was long, but the questions were fair.", "gsat_level": 3},
    {"name": "Comma Splices", "category": "writing_errors", "description": "Avoid joining independent clauses with only a comma.", "example_sentence": "The article was clear; the chart was more difficult.", "gsat_level": 4},
    {"name": "Ellipsis", "category": "sentence_structure", "description": "Omit repeated words when grammar and meaning remain clear.", "example_sentence": "Some students chose A, and others B.", "gsat_level": 5},
    {"name": "So and Such", "category": "degree", "description": "Use so with adjectives/adverbs and such with noun phrases.", "example_sentence": "It was such a useful lesson that everyone took notes.", "gsat_level": 3},
    {"name": "Enough and Too", "category": "degree", "description": "Express sufficiency and excess with correct word order.", "example_sentence": "The explanation was clear enough for beginners.", "gsat_level": 3},
    {"name": "As If and As Though", "category": "subjunctive", "description": "Use unreal comparison clauses with appropriate verb forms.", "example_sentence": "He spoke as if he had already seen the answer.", "gsat_level": 5},
    {"name": "No Matter Wh- Clauses", "category": "concession", "description": "Use no matter what, whether, or however to express concession.", "example_sentence": "No matter how hard the passage is, read the question first.", "gsat_level": 4},
]


FALLBACK_VOCAB: list[dict[str, Any]] = [
    {"word": "abundant", "translation": "豐富的", "part_of_speech": "adj.", "gsat_level": 4, "gsat_frequency": 86, "example_sentence": "The island has abundant natural resources."},
    {"word": "accurate", "translation": "準確的", "part_of_speech": "adj.", "gsat_level": 3, "gsat_frequency": 92, "example_sentence": "Students need accurate information before making decisions."},
    {"word": "adapt", "translation": "適應；改編", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 88, "example_sentence": "Teenagers must adapt to a rapidly changing world."},
    {"word": "adequate", "translation": "足夠的", "part_of_speech": "adj.", "gsat_level": 4, "gsat_frequency": 74, "example_sentence": "Adequate sleep improves learning efficiency."},
    {"word": "analyze", "translation": "分析", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 90, "example_sentence": "The class learned how to analyze charts."},
    {"word": "approach", "translation": "方法；接近", "part_of_speech": "n./v.", "gsat_level": 3, "gsat_frequency": 95, "example_sentence": "A balanced approach can reduce exam pressure."},
    {"word": "benefit", "translation": "益處；受益", "part_of_speech": "n./v.", "gsat_level": 3, "gsat_frequency": 93, "example_sentence": "Daily reading can benefit language learners."},
    {"word": "challenge", "translation": "挑戰", "part_of_speech": "n./v.", "gsat_level": 3, "gsat_frequency": 94, "example_sentence": "The project was a challenge for the whole team."},
    {"word": "consequence", "translation": "後果", "part_of_speech": "n.", "gsat_level": 4, "gsat_frequency": 81, "example_sentence": "Every choice has a possible consequence."},
    {"word": "consistent", "translation": "一致的；持續的", "part_of_speech": "adj.", "gsat_level": 4, "gsat_frequency": 83, "example_sentence": "Consistent practice leads to better results."},
    {"word": "consume", "translation": "消耗；消費", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 76, "example_sentence": "Social media can consume too much time."},
    {"word": "contribute", "translation": "貢獻；促成", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 87, "example_sentence": "Volunteers contribute to the local community."},
    {"word": "demonstrate", "translation": "展示；證明", "part_of_speech": "v.", "gsat_level": 5, "gsat_frequency": 79, "example_sentence": "The experiment demonstrates the importance of clean water."},
    {"word": "efficient", "translation": "有效率的", "part_of_speech": "adj.", "gsat_level": 4, "gsat_frequency": 85, "example_sentence": "An efficient schedule leaves time for rest."},
    {"word": "emphasize", "translation": "強調", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 82, "example_sentence": "The speaker emphasized the value of teamwork."},
    {"word": "essential", "translation": "必要的；本質的", "part_of_speech": "adj.", "gsat_level": 4, "gsat_frequency": 91, "example_sentence": "Critical thinking is essential in modern education."},
    {"word": "evaluate", "translation": "評估", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 86, "example_sentence": "Teachers evaluate essays by content and clarity."},
    {"word": "evidence", "translation": "證據", "part_of_speech": "n.", "gsat_level": 4, "gsat_frequency": 89, "example_sentence": "The writer supports the claim with evidence."},
    {"word": "expand", "translation": "擴展", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 78, "example_sentence": "Reading can expand your vocabulary."},
    {"word": "factor", "translation": "因素", "part_of_speech": "n.", "gsat_level": 3, "gsat_frequency": 90, "example_sentence": "Weather is an important factor in travel plans."},
    {"word": "impact", "translation": "影響", "part_of_speech": "n./v.", "gsat_level": 4, "gsat_frequency": 94, "example_sentence": "Technology has a major impact on learning."},
    {"word": "imply", "translation": "暗示", "part_of_speech": "v.", "gsat_level": 5, "gsat_frequency": 73, "example_sentence": "The final paragraph implies that change is possible."},
    {"word": "indicate", "translation": "指出；顯示", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 84, "example_sentence": "The chart indicates a steady increase."},
    {"word": "maintain", "translation": "維持；主張", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 80, "example_sentence": "Students should maintain healthy routines."},
    {"word": "obstacle", "translation": "障礙", "part_of_speech": "n.", "gsat_level": 4, "gsat_frequency": 75, "example_sentence": "Fear of failure can become an obstacle."},
    {"word": "participate", "translation": "參與", "part_of_speech": "v.", "gsat_level": 3, "gsat_frequency": 88, "example_sentence": "More students participate in environmental clubs."},
    {"word": "perspective", "translation": "觀點", "part_of_speech": "n.", "gsat_level": 5, "gsat_frequency": 77, "example_sentence": "Travel can change a person's perspective."},
    {"word": "potential", "translation": "潛力；潛在的", "part_of_speech": "n./adj.", "gsat_level": 4, "gsat_frequency": 84, "example_sentence": "The program helps students discover their potential."},
    {"word": "preserve", "translation": "保存；保護", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 76, "example_sentence": "Museums preserve important cultural memories."},
    {"word": "prevent", "translation": "防止", "part_of_speech": "v.", "gsat_level": 3, "gsat_frequency": 90, "example_sentence": "Regular exercise can prevent health problems."},
    {"word": "promote", "translation": "促進；推廣", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 87, "example_sentence": "The campaign promotes reading among teenagers."},
    {"word": "reliable", "translation": "可靠的", "part_of_speech": "adj.", "gsat_level": 4, "gsat_frequency": 80, "example_sentence": "Reliable sources are important for research."},
    {"word": "require", "translation": "需要；要求", "part_of_speech": "v.", "gsat_level": 3, "gsat_frequency": 93, "example_sentence": "The task requires careful planning."},
    {"word": "resource", "translation": "資源", "part_of_speech": "n.", "gsat_level": 3, "gsat_frequency": 88, "example_sentence": "The library offers many useful resources."},
    {"word": "respond", "translation": "回應", "part_of_speech": "v.", "gsat_level": 3, "gsat_frequency": 86, "example_sentence": "The company responded quickly to the problem."},
    {"word": "significant", "translation": "重要的；顯著的", "part_of_speech": "adj.", "gsat_level": 4, "gsat_frequency": 91, "example_sentence": "The study shows a significant difference."},
    {"word": "strategy", "translation": "策略", "part_of_speech": "n.", "gsat_level": 4, "gsat_frequency": 85, "example_sentence": "A good strategy makes review less stressful."},
    {"word": "sustainable", "translation": "永續的", "part_of_speech": "adj.", "gsat_level": 5, "gsat_frequency": 78, "example_sentence": "Cities need sustainable transportation systems."},
    {"word": "transform", "translation": "轉變", "part_of_speech": "v.", "gsat_level": 4, "gsat_frequency": 76, "example_sentence": "Small habits can transform learning."},
    {"word": "various", "translation": "各種的", "part_of_speech": "adj.", "gsat_level": 3, "gsat_frequency": 94, "example_sentence": "The article discusses various solutions."},
]


def load_rc_fallback_vocab() -> list[dict[str, Any]]:
    data_path = CURRENT_DIR / "data" / "rc_vocab_seed.json"
    try:
        payload = json.loads(data_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Unable to load RC vocabulary seed data: {exc}") from exc
    if not isinstance(payload, list):
        raise RuntimeError("RC vocabulary seed data must be a JSON array.")
    return [item for item in payload if isinstance(item, dict)]


RC_FALLBACK_VOCAB = load_rc_fallback_vocab()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Seed GSAT vocabulary and grammar concepts.")
    parser.add_argument("--vocab", type=int, default=500, help="Number of vocabulary words to seed.")
    parser.add_argument("--grammar", type=int, default=50, help="Number of grammar concepts to seed.")
    parser.add_argument("--batch-size", type=int, default=50, help="Vocabulary generation batch size.")
    parser.add_argument(
        "--database-url",
        default=os.getenv("DATABASE_URL", DEFAULT_DATABASE_URL),
        help="SQLAlchemy database URL. Defaults to backend/gsat_english.db.",
    )
    parser.add_argument("--model", default=CODEX_MODEL, help="OpenAI-compatible model name.")
    parser.add_argument("--openai-base-url", default=OPENAI_BASE_URL)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument(
        "--offline-fallback",
        action="store_true",
        help="Use embedded fallback content if OPENAI_API_KEY is absent or a generation batch fails.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Generate and report without writing rows.")
    return parser.parse_args()


def create_session(database_url: str) -> sessionmaker[Session]:
    database_url = normalize_database_url(database_url)
    migration_config = AlembicConfig(str(PROJECT_ROOT / "alembic.ini"))
    migration_config.attributes["database_url"] = database_url
    alembic_command.upgrade(migration_config, "head")
    engine = create_engine(
        database_url,
        connect_args={"check_same_thread": False} if database_url.startswith("sqlite") else {},
    )
    return sessionmaker(autocommit=False, autoflush=False, bind=engine)


def call_codex_json(prompt: str, *, model: str, base_url: str, timeout: float) -> Any:
    if not OPENAI_API_KEY:
        raise RuntimeError("OPENAI_API_KEY is not configured.")

    payload = {
        "model": model,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You generate authentic Taiwanese GSAT English seed data. "
                    "Return strict JSON only. No markdown fences."
                ),
            },
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.35,
    }
    headers = {
        "Authorization": f"Bearer {OPENAI_API_KEY}",
        "Content-Type": "application/json",
    }
    with httpx.Client(timeout=timeout) as client:
        response = client.post(
            f"{base_url.rstrip('/')}/chat/completions",
            headers=headers,
            json=payload,
        )
        response.raise_for_status()
    content = response.json()["choices"][0]["message"]["content"]
    return parse_json_from_text(content)


def parse_json_from_text(text_value: str) -> Any:
    text_value = text_value.strip()
    try:
        return json.loads(text_value)
    except json.JSONDecodeError:
        pass
    match = re.search(r"(\[[\s\S]*\]|\{[\s\S]*\})", text_value)
    if not match:
        raise ValueError("LLM response did not contain JSON.")
    return json.loads(match.group(1))


def normalize_vocab_item(item: dict[str, Any]) -> dict[str, Any] | None:
    word = str(item.get("word") or "").strip().lower()
    if not re.fullmatch(r"[a-z][a-z -]{1,48}", word):
        return None
    translation = str(
        item.get("translation") or item.get("chinese_translation") or item.get("definition") or ""
    ).strip()
    example = str(item.get("example_sentence") or item.get("example") or "").strip()
    part_of_speech = str(item.get("part_of_speech") or item.get("pos") or "").strip()[:40]
    try:
        level = int(item.get("gsat_level") or item.get("level") or 4)
    except (TypeError, ValueError):
        level = 4
    try:
        frequency = int(item.get("gsat_frequency") or item.get("frequency") or 50)
    except (TypeError, ValueError):
        frequency = 50
    return {
        "word": word,
        "translation": translation[:500] or "待補中文翻譯",
        "part_of_speech": part_of_speech or None,
        "gsat_level": max(3, min(5, level)),
        "gsat_frequency": max(1, min(100, frequency)),
        "example_sentence": example[:500] or f"Students should learn how to use {word} in context.",
    }


def normalize_concept_item(item: dict[str, Any]) -> dict[str, Any] | None:
    name = str(item.get("name") or item.get("concept") or "").strip()
    if not name:
        return None
    try:
        level = int(item.get("gsat_level") or item.get("level") or 4)
    except (TypeError, ValueError):
        level = 4
    return {
        "name": name[:120],
        "category": str(item.get("category") or "core_grammar").strip()[:120],
        "description": str(item.get("description") or "").strip()[:1000],
        "example_sentence": str(item.get("example_sentence") or item.get("example") or "").strip()[:500],
        "gsat_level": max(3, min(5, level)),
    }


def generate_vocab_batch(
    *,
    count: int,
    existing_words: set[str],
    model: str,
    base_url: str,
    timeout: float,
) -> list[dict[str, Any]]:
    prompt = (
        f"Generate exactly {count} unique high-frequency Taiwanese GSAT English vocabulary words "
        "at Level 3-5. Avoid obscure TOEFL/GRE words. Return ONLY a JSON array. "
        "Each item must have: word, translation (Traditional Chinese), part_of_speech, "
        "gsat_level (3, 4, or 5), gsat_frequency (1-100), example_sentence. "
        "Example sentences should be natural and GSAT-appropriate.\n\n"
        f"Do NOT include these existing words: {', '.join(sorted(existing_words)[-350:])}"
    )
    raw = call_codex_json(prompt, model=model, base_url=base_url, timeout=timeout)
    if isinstance(raw, dict):
        raw = raw.get("words") or raw.get("vocabulary") or []
    if not isinstance(raw, list):
        raise ValueError("Vocabulary response was not a JSON array.")
    items: list[dict[str, Any]] = []
    seen = set(existing_words)
    for raw_item in raw:
        if not isinstance(raw_item, dict):
            continue
        item = normalize_vocab_item(raw_item)
        if item is None or item["word"] in seen:
            continue
        seen.add(item["word"])
        items.append(item)
    return items


def generate_grammar_concepts(
    *,
    count: int,
    model: str,
    base_url: str,
    timeout: float,
) -> list[dict[str, Any]]:
    prompt = (
        f"Generate exactly {count} core Taiwanese GSAT English grammar concepts. "
        "Return ONLY a JSON array. Each item must have: name, category, description, "
        "example_sentence, gsat_level (3, 4, or 5). Include concepts such as Inversion, "
        "Subjunctive Mood, Participle Clauses, Relative Clauses, and transition logic, "
        "but avoid duplicates."
    )
    raw = call_codex_json(prompt, model=model, base_url=base_url, timeout=timeout)
    if isinstance(raw, dict):
        raw = raw.get("concepts") or raw.get("grammar_concepts") or []
    if not isinstance(raw, list):
        raise ValueError("Grammar response was not a JSON array.")
    items: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw_item in raw:
        if not isinstance(raw_item, dict):
            continue
        item = normalize_concept_item(raw_item)
        if item is None or item["name"].lower() in seen:
            continue
        seen.add(item["name"].lower())
        items.append(item)
    return items[:count]


def upsert_vocab(db: Session, item: dict[str, Any]) -> bool:
    vocabulary = db.scalar(select(Vocabulary).where(Vocabulary.word == item["word"]))
    inserted = vocabulary is None
    if vocabulary is None:
        vocabulary = Vocabulary(word=item["word"], created_at=datetime.utcnow())
        db.add(vocabulary)
    vocabulary.definition = item["translation"]
    vocabulary.part_of_speech = item["part_of_speech"]
    vocabulary.gsat_level = item["gsat_level"]
    vocabulary.gsat_frequency = item["gsat_frequency"]
    vocabulary.source_context = item["example_sentence"]
    return inserted


def upsert_concept(db: Session, item: dict[str, Any]) -> bool:
    concept = db.scalar(select(GrammarConceptBank).where(GrammarConceptBank.name == item["name"]))
    inserted = concept is None
    if concept is None:
        concept = GrammarConceptBank(name=item["name"], created_at=datetime.utcnow())
        db.add(concept)
    concept.category = item["category"]
    concept.description = item["description"]
    concept.example_sentence = item["example_sentence"]
    concept.gsat_level = item["gsat_level"]
    return inserted


def seed_vocab(args: argparse.Namespace, session_factory: sessionmaker[Session]) -> int:
    if args.vocab <= 0:
        return 0
    inserted_total = 0
    with session_factory() as db:
        existing_words = set(db.scalars(select(Vocabulary.word)).all())
    target_insertions = max(0, args.vocab - len(existing_words))
    if target_insertions == 0:
        print(f"[vocab] target already met: {len(existing_words)}/{args.vocab}")
        return 0

    attempts = 0
    while inserted_total < target_insertions and attempts < max(5, (target_insertions // args.batch_size) + 8):
        attempts += 1
        remaining = target_insertions - inserted_total
        batch_count = min(args.batch_size, remaining)
        try:
            items = generate_vocab_batch(
                count=batch_count,
                existing_words=existing_words,
                model=args.model,
                base_url=args.openai_base_url,
                timeout=args.timeout,
            )
        except Exception as exc:
            if not args.offline_fallback:
                raise RuntimeError(
                    f"Vocabulary batch generation failed: {exc}. "
                    "Set OPENAI_API_KEY or rerun with --offline-fallback."
                ) from exc
            print(f"[warn] vocab batch failed; using fallback entries: {exc}")
            items = [
                item
                for item in [*FALLBACK_VOCAB, *RC_FALLBACK_VOCAB]
                if item["word"] not in existing_words
            ][:batch_count]
            if not items:
                break

        with session_factory() as db:
            batch_inserted = 0
            for item in items:
                if item["word"] in existing_words:
                    continue
                if upsert_vocab(db, item):
                    batch_inserted += 1
                existing_words.add(item["word"])
            if not args.dry_run:
                db.commit()
            else:
                db.rollback()
            inserted_total += batch_inserted
            print(
                f"[vocab] batch {attempts}: inserted {batch_inserted}; "
                f"database total {len(existing_words)}/{args.vocab}"
            )
        if not items:
            break
    return inserted_total


def seed_grammar(args: argparse.Namespace, session_factory: sessionmaker[Session]) -> int:
    if args.grammar <= 0:
        return 0
    with session_factory() as db:
        existing_names = {
            name.lower() for name in db.scalars(select(GrammarConceptBank.name)).all()
        }
    needed = max(0, args.grammar - len(existing_names))
    if needed == 0:
        print(f"[grammar] target already met: {len(existing_names)}/{args.grammar}")
        return 0
    try:
        items = generate_grammar_concepts(
            count=args.grammar,
            model=args.model,
            base_url=args.openai_base_url,
            timeout=args.timeout,
        )
    except Exception as exc:
        if not args.offline_fallback:
            raise RuntimeError(
                f"Grammar concept generation failed: {exc}. "
                "Set OPENAI_API_KEY or rerun with --offline-fallback."
            ) from exc
        print(f"[warn] grammar generation failed; using fallback concepts: {exc}")
        items = [
            item
            for item in FALLBACK_GRAMMAR_CONCEPTS
            if item["name"].lower() not in existing_names
        ][:needed]

    inserted = 0
    with session_factory() as db:
        for item in items:
            normalized = normalize_concept_item(item)
            if (
                normalized
                and normalized["name"].lower() not in existing_names
                and upsert_concept(db, normalized)
            ):
                inserted += 1
                existing_names.add(normalized["name"].lower())
                if inserted >= needed:
                    break
        if not args.dry_run:
            db.commit()
        else:
            db.rollback()
    print(f"[grammar] inserted {inserted}; database target {args.grammar}")
    return inserted


def main() -> None:
    args = parse_args()
    args.batch_size = max(1, min(50, args.batch_size))
    session_factory = create_session(args.database_url)
    print(f"[seed] database: {args.database_url}")
    print(f"[seed] model: {args.model}")
    vocab_inserted = seed_vocab(args, session_factory)
    grammar_inserted = seed_grammar(args, session_factory)
    print(
        json.dumps(
            {
                "vocab_inserted": vocab_inserted,
                "grammar_concepts_inserted": grammar_inserted,
                "dry_run": args.dry_run,
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
