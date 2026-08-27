# Owner Actions

Do not paste secrets into chat or commit `.env`.

## 1. Install Android Tooling

Project-local JDK 17 and Android command-line tools are already installed. The owner must personally accept Google's SDK terms:

```powershell
$env:JAVA_HOME=(Resolve-Path '.\.tools\jdk17').Path
$sdk=(Resolve-Path '.\.tools\android-sdk').Path
.\.tools\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat --sdk_root=$sdk --licenses
```

Enter `y` for each agreement you accept. Then install Platform 36, Build Tools, Platform Tools, NDK, and an Emulator image, start the Emulator, and run the Android commands from `docs/CLOSED_BETA_RC.md`.

```powershell
.\.tools\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat --sdk_root=$sdk "platform-tools" "platforms;android-36" "build-tools;36.0.0" "ndk;28.2.13676358" "emulator" "system-images;android-35;google_apis;x86_64"
"no" | .\.tools\android-sdk\cmdline-tools\latest\bin\avdmanager.bat create avd --force --name GSAT_Max_API_35 --package "system-images;android-35;google_apis;x86_64" --device "pixel_7"
& "$sdk\emulator\emulator.exe" -avd GSAT_Max_API_35
```

## 2. Install Tesseract OCR

1. Install Tesseract on every backend host. On Windows, run `winget install --id tesseract-ocr.tesseract --exact` or use the official UB Mannheim installer.
2. Set `TESSERACT_CMD=C:\Program Files\Tesseract-OCR\tesseract.exe` in `.env` if the executable is not on `PATH`.
3. Restart FastAPI and upload clear, blurred, and rotated exam scans to `/upload/exam/analyze-mistakes`.
4. Confirm OCR text, corrected mistakes, Error Ledger writes, and next-day expansion jobs.

## 3. Configure AI

1. Copy `.env.example` to `.env`.
2. For the lowest-cost setup, create a Gemini API key and set `GEMINI_API_KEY`; optionally create a Groq key and set `GROQ_API_KEY` as the text fallback.
3. The default router order is `gemini,groq,openai,ollama`. `OPENAI_API_KEY` is optional, and all keys must remain server-side.
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
4. Replace SQLite with managed PostgreSQL before broad public scale; Alembic is already active and every deployment must run `alembic upgrade head`.
5. Run `python -m backend.release_preflight --from-environ --frontend-origin https://your-domain` on the host before each release and resolve every reported failure. It reads no secret values and never opens the configured database -- the migrations are rehearsed on a throwaway SQLite database in a temporary directory; see `docs/WEB_DEPLOYMENT.md`.

## 7. Device and Store Acceptance

1. Test camera, gallery, TTS, notification permission/timezone scheduling, PDF open, native sharing, and account deletion on real Android and iOS devices.
2. Review Terms/Privacy text with counsel and replace placeholder support email/domain.
3. Approve or replace provisional `assets/icon.png` and `assets/splash.png`, then regenerate assets.
