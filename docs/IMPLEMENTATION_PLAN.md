# GSAT_Max Closed Beta Implementation Plan

## Phase 0 - Baseline

- [x] Inspect workspace, dependencies, routes, models, configuration, and Git state.
- [x] Install project-local Flutter 3.44.7 and create non-destructive platform scaffolding.
- [x] Capture `flutter doctor`, analyze, test, build, Python compile, pytest, and health output.

## Phase 1 - Executable Foundation

- [x] Centralize Flutter API configuration with platform defaults and `--dart-define`.
- [x] Add `.env` loading, CORS allowlist, production secret guard, and `/health`.
- [x] Unify Python requirements and add Windows/Unix startup scripts.
- [x] Make Seed target-based and idempotent; verify two runs on a clean database.

## Phase 2 - Account and Learning Data

- [x] Replace mock tokens with secure access/refresh storage and session restore.
- [x] Add refresh rotation, logout revocation, email verification, and password reset APIs.
- [x] Persist daily missions, task completion, seven-day weekly counts, and target exam date.
- [x] Isolate offline review queues by user and make backend updates idempotent.

## Phase 3 - Authoritative Assessment

- [x] Return and render schema-validated Writing scores, corrections, templates, and vocabulary.
- [x] Save original essays, evaluation JSON, and rubric version.
- [x] Store full mock exam versions, hide answer keys, and grade all submissions server-side.
- [x] Remove word-count and client answer-key scoring.

## Phase 4 - Background Reliability

- [x] Queue OCR expansion generation with job status, retry, idempotency, and next-day due dates.
- [x] Queue full mock exam generation and poll it from Flutter.
- [x] Reuse semantic cache and completed version jobs as the initial Closed Beta exam pool.

## Phase 5 - Pro and Security

- [x] Block direct self-upgrade and use a RevenueCat webhook for server entitlement.
- [x] Add Offering/package purchase, cancellation, restore, and server sync states.
- [x] Add admin role checks, rate limits, upload byte/MIME/content validation, and CORS.
- [x] Reject default/short JWT secrets in production.

## Phase 6-7 - Native, Web, Tests, and Release

- [x] Generate Android/iOS/Web scaffolding, permissions, provisional icon, and splash.
- [x] Build Web successfully and replace image path APIs with byte-based upload/preview.
- [x] Add Flutter tests, backend integration tests, and GitHub Actions CI.
- [x] Add verified README, verification log, and Owner Actions.
- [ ] Build an Android APK locally (blocked by missing Android SDK on this workstation).
- [ ] Perform real AI, OCR, notification, RevenueCat sandbox, and store-device acceptance.
- [ ] Continue incremental `lib/main.dart` and backend router/service decomposition after beta stabilization.

## Phase 8 - Learning Momentum and Low-Screen Access

- [x] Add learner-owned weekday/weekend budgets and instant 3/10/20/45-minute replanning.
- [x] Add high-success micro wins, effort-based points, levels, weekly goals, comeback tracking, and one-day streak shields.
- [x] Add an idempotent learning event ledger so offline retries cannot duplicate rewards.
- [x] Generate five-day A4 paper packs with vocabulary, grammar, reading, answer keys, completion codes, and progress sync.
- [x] Add Gemini/Groq/OpenAI/Ollama provider routing, fallback metrics, and basic student-text PII redaction.
- [x] Add migration and behavior tests for all new persistence and document workflows.

## Phase 9 - Responsive Website and PWA Delivery

- [x] Reuse the authenticated Flutter application as a responsive Web/PWA instead of a separate marketing shell.
- [x] Add phone, iPad and desktop breakpoints, max content widths, adaptive navigation rail, and one/two/three-column feature grids.
- [x] Add Web-native PDF downloads, same-origin `/api` resolution, production HTTPS guards, and expanded local CORS origins.
- [x] Add Traditional Chinese PWA/SEO metadata, robots, caching/security headers, and bundled Noto Sans TC typography.
- [x] Add Nginx/FastAPI Dockerfiles, a persistent SQLite Compose stack, Web build/start scripts, and CI Web artifacts.
- [x] Verify the release UI through register, onboarding, Home, Diagnostic, Profile and PDF download at desktop, iPad and phone viewports.
