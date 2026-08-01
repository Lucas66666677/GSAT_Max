# Verification Log

Verified on Windows 11, Python 3.11.9, Flutter 3.44.7, Dart 3.12.2.

| Check | Result |
| --- | --- |
| `flutter pub get` | PASS |
| `flutter analyze` | PASS, no issues found; executed through `C:\gsat_max_workspace` ASCII junction to avoid the Flutter analysis-server JSON bug on a Chinese workspace path |
| `flutter test` | PASS, 23 tests |
| `flutter build web --release` | PASS, output `build/web` |
| Browser UI smoke test | PASS; `/#/login` rendered correctly and browser console had no errors |
| Python `compileall` | PASS |
| Backend `pytest` | PASS, 27 tests |
| Clean FastAPI startup | PASS |
| `GET /health` on Uvicorn | PASS; database reachable |
| Seed target | PASS; real database contains 513 vocab + 50 grammar concepts |
| Seed idempotency | PASS; two consecutive 500/50 runs inserted 0/0 |
| Alembic | PASS; clean upgrade, downgrade, baseline-data upgrade, and production DB upgrade to `9c52b7f79fd4` |
| Time-budget planner | PASS; 3-minute plan stays within budget, starts with a 95% success-target micro win, and preserves completed work across replans |
| Reward ledger | PASS; points, levels, weekly activity, comeback/shield state, and repeated-action idempotency |
| Weekly print pack | PASS; five-day payload, real 7-page A4 PDF, embedded Noto Sans TC font, completion code, multi-day progress, duplicate submission protection, and Poppler PNG visual review |
| AI provider router | PASS with mocked upstreams; Gemini to Groq fallback, provider/model metrics, and text PII redaction |
| Production default-secret guard | PASS; startup rejected with the expected `RuntimeError` |
| Native icon generation | PASS, Android and iOS resources generated |
| Native splash generation | PASS, Android/iOS/Web resources generated |
| Android debug build | OWNER ACTION: project-local JDK 17 and official Android command-line tools are installed; Google SDK licenses are not accepted, so Platform 36 / Build Tools / NDK cannot be installed yet |
| Tesseract OCR executable | PASS; Tesseract 5.5.3 recognized `backend/tests/fixtures/exam_sample.png` and the OCR/error-expansion persistence test passes |
| Real AI inference | BLOCKED: no Owner API key / Ollama runtime |
| RevenueCat sandbox | BLOCKED: no Owner store products or account configuration |

Backend coverage includes protected route boundaries, registration/session refresh rotation, email verification, password reset, direct Pro upgrade rejection, time-budget mission persistence, reward idempotency, printable study packs, target date, vocabulary review, SM-2, sync idempotency, MIME rejection, OCR persistence, writing schema validation, mock answer-key sanitization, authoritative mock grading, AI provider fallback, PII redaction, and background job status.

The Web release build reports Wasm dry-run incompatibilities in third-party secure-storage/timezone/TTS packages. The normal JavaScript Web release build succeeds. Package update notices are informational; dependencies remain locked by `pubspec.lock` for the RC.
