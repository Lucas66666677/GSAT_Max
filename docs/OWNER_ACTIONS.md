# Owner Actions

Do not paste secrets into chat or commit `.env`.

## 1. Install Android Tooling

1. Install Android Studio from the official Android developer site.
2. In SDK Manager install Android SDK Platform, Build Tools, Command-line Tools, and an Emulator image.
3. Run `flutter config --android-sdk <SDK_PATH>` if Flutter does not discover it.
4. Accept licenses with `flutter doctor --android-licenses`.
5. Start an emulator and run the APK commands from `README.md`.

## 2. Install Tesseract OCR

1. Install Tesseract on every backend host. On Windows, run `winget install --id tesseract-ocr.tesseract --exact` or use the official UB Mannheim installer.
2. Set `TESSERACT_CMD=C:\Program Files\Tesseract-OCR\tesseract.exe` in `.env` if the executable is not on `PATH`.
3. Restart FastAPI and upload clear, blurred, and rotated exam scans to `/upload/exam/analyze-mistakes`.
4. Confirm OCR text, corrected mistakes, Error Ledger writes, and next-day expansion jobs.

## 3. Configure AI

1. Copy `.env.example` to `.env`.
2. In the selected OpenAI-compatible provider, create a server-side API key.
3. Put it in `OPENAI_API_KEY`; set `OPENAI_BASE_URL` and `CODEX_MODEL` to a model with text and vision support.
4. Alternatively install Ollama, pull `OLLAMA_MODEL`, and verify `OLLAMA_BASE_URL` from the backend host.
5. Start FastAPI and manually verify Writing, OCR, Reading, Grammar, and full mock generation.

## 4. Configure RevenueCat and Stores

1. Create Android/iOS apps, the monthly `$4.99` product, `pro` entitlement, and a current Offering in RevenueCat.
2. Pass each platform's public SDK key as `--dart-define=REVENUECAT_API_KEY=...`.
3. Generate a webhook authorization secret and store it as backend `REVENUECAT_WEBHOOK_AUTH`.
4. Point RevenueCat to `https://<API_DOMAIN>/integrations/revenuecat/webhook`.
5. Verify purchase, cancellation, restore, renewal, expiration, and transfer with sandbox users.

## 5. Production Email and Links

1. Select an email provider and implement its adapter behind `backend/email_service.py`.
2. Set `EMAIL_PROVIDER` and `EMAIL_FROM` in the deployment secret manager.
3. Configure HTTPS verification/password-reset links or app deep links that submit tokens to the existing confirm endpoints.
4. Test delivery, expiration, token reuse rejection, and password-reset session revocation.

## 6. Production Infrastructure

1. Provision an HTTPS API domain, host, persistent database volume, backups, and monitoring.
2. Set `APP_ENV=production`, a random `JWT_SECRET_KEY` of at least 32 characters, exact `API_CORS_ORIGINS`, and all provider secrets.
3. Move rate-limit/job state to shared infrastructure before running more than one API process.
4. Replace SQLite with managed PostgreSQL before broad public scale; introduce Alembic migrations.

## 7. Device and Store Acceptance

1. Test camera, gallery, TTS, notification permission/timezone scheduling, PDF open, native sharing, and account deletion on real Android and iOS devices.
2. Review Terms/Privacy text with counsel and replace placeholder support email/domain.
3. Approve or replace provisional `assets/icon.png` and `assets/splash.png`, then regenerate assets.
