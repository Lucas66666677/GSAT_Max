# Verification Log

Verified on Windows 11, Python 3.11.9, Flutter 3.44.7, Dart 3.12.2.

| Check | Result |
| --- | --- |
| `flutter pub get` | PASS |
| `flutter analyze` | PASS, no issues found |
| `flutter test` | PASS, 3 tests |
| `flutter build web --release` | PASS, output `build/web` |
| Browser UI smoke test | PASS; `/#/login` rendered correctly and browser console had no errors |
| Python `compileall` | PASS |
| Backend `pytest` | PASS, 11 tests |
| Clean FastAPI startup | PASS |
| `GET /health` on Uvicorn | PASS; database reachable |
| Seed run 1 | PASS; 20 vocab + 10 grammar inserted |
| Seed run 2 | PASS; 0 inserted, totals unchanged |
| Production default-secret guard | PASS; startup rejected with the expected `RuntimeError` |
| Native icon generation | PASS, Android and iOS resources generated |
| Native splash generation | PASS, Android/iOS/Web resources generated |
| Android debug build | ENVIRONMENT-BLOCKED: command reached Android toolchain check, then reported `No Android SDK found`; automated winget toolchain install was attempted but did not complete |
| Tesseract OCR executable | ENVIRONMENT-BLOCKED: winget install did not complete on this workstation; `TESSERACT_CMD` configuration is implemented |
| Real AI inference | BLOCKED: no Owner API key / Ollama runtime |
| RevenueCat sandbox | BLOCKED: no Owner store products or account configuration |

Backend coverage includes protected route boundaries, registration/session refresh rotation, email verification, password reset, direct Pro upgrade rejection, mission persistence, target date, vocabulary review, SM-2, sync idempotency, MIME rejection, writing schema validation, mock answer-key sanitization, authoritative mock grading, and background job status.

The Web release build reports Wasm dry-run incompatibilities in third-party secure-storage/timezone/TTS packages. The normal JavaScript Web release build succeeds. Package update notices are informational; dependencies remain locked by `pubspec.lock` for the RC.
