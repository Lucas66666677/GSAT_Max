# GSAT_Max

GSAT_Max 是面向台灣高中生的學測英文訓練 App。前端使用 Flutter、Riverpod、GoRouter 與 Material 3；後端使用 FastAPI、SQLAlchemy 與 SQLite。

## 已驗證環境

- Python 3.11
- Flutter 3.44.7 / Dart 3.12.2
- Chrome Web release build
- Android 為 Closed Beta 第一目標；本機建置仍需 Android Studio、Android SDK 與 Emulator

> Windows 注意：目前工作區路徑含中文。若 Flutter 工具出現路徑解析或 analyzer crash，請先建立 ASCII junction，再從該目錄執行 Flutter 指令：
>
> ```powershell
> New-Item -ItemType Directory -Force C:\dev | Out-Null
> New-Item -ItemType Junction -Path C:\dev\gsat_max -Target (Get-Location)
> Set-Location C:\dev\gsat_max
> ```

## 後端啟動（Windows PowerShell）

```powershell
Copy-Item .env.example .env
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\scripts\seed_data.ps1 -Vocab 500 -Grammar 50 -OfflineFallback
.\scripts\start_backend.ps1 -SkipInstall -Port 8000
```

開啟 `http://127.0.0.1:8000/health`，應回傳 `status: ok`。尚未設定 AI Key 時仍可啟動、登入、操作資料層及跑測試，但 AI 生成端點無法完成真實推論。

## AI 與環境變數

`.env` 只放在本機或 Secret Manager，不可提交。主要變數：

```dotenv
APP_ENV=development
DATABASE_URL=sqlite:///./backend/gsat_english.db
API_CORS_ORIGINS=http://localhost:8080
JWT_SECRET_KEY=replace-with-at-least-32-random-characters
OPENAI_API_KEY=
OPENAI_BASE_URL=https://api.openai.com/v1
CODEX_MODEL=gpt-4o-mini
OLLAMA_BASE_URL=http://localhost:11434
OLLAMA_MODEL=llama3.1
REVENUECAT_WEBHOOK_AUTH=
TESSERACT_CMD=C:\Program Files\Tesseract-OCR\tesseract.exe
```

正式環境必須使用非預設 JWT Secret，否則後端拒絕啟動。完整欄位請看 `.env.example`。
OCR 還需要在後端主機安裝 Tesseract；Windows 可執行：

```powershell
winget install --id tesseract-ocr.tesseract --exact
```

## Flutter 啟動

若使用專案內 Flutter SDK：

```powershell
.\.tools\flutter\bin\flutter.bat pub get
.\.tools\flutter\bin\flutter.bat analyze
.\.tools\flutter\bin\flutter.bat test
```

Chrome：

```powershell
.\.tools\flutter\bin\flutter.bat run -d chrome --web-port 8080 `
  --dart-define=API_BASE_URL=http://localhost:8000
```

Android Emulator：

```powershell
.\.tools\flutter\bin\flutter.bat run -d emulator-5554 `
  --dart-define=API_BASE_URL=http://10.0.2.2:8000 `
  --dart-define=REVENUECAT_API_KEY=your_public_android_sdk_key
```

Android 實機需把 `API_BASE_URL` 換成開發電腦區網位址，例如 `http://192.168.1.20:8000`，並確保防火牆允許連線。Production build 必須傳入 HTTPS URL。

## 驗證與建置

```powershell
.\.venv\Scripts\python.exe -m compileall -q backend
.\.venv\Scripts\python.exe -m pytest backend/tests -q
.\.tools\flutter\bin\flutter.bat build web --release `
  --dart-define=API_BASE_URL=http://localhost:8000
.\.tools\flutter\bin\flutter.bat build apk --debug `
  --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

App Icon 與 Splash 已生成。替換 `assets/icon.png`、`assets/splash.png` 後重跑：

```powershell
.\.tools\flutter\bin\dart.bat run flutter_launcher_icons
.\.tools\flutter\bin\dart.bat run flutter_native_splash:create
```

## 目錄重點

- `lib/main.dart`：現有功能 UI 與主要流程
- `lib/core/config/app_config.dart`：跨平台 API／RevenueCat build 設定
- `lib/core/services/purchase_service.dart`：RevenueCat 購買與恢復介面
- `backend/main.py`：API、認證、AI、背景工作與資料流程
- `backend/models.py`：SQLAlchemy 模型
- `backend/seed_data.py`：可重複執行的 GSAT Seed CLI
- `backend/tests/`、`test/`：後端與 Flutter 自動化測試
- `docs/`：執行計畫、驗證紀錄與 Owner Actions

## 外部服務

RevenueCat 商品、商店帳號、正式 Email Provider、AI Key、HTTPS 主機與正式品牌素材仍需由 Owner 在外部後台完成。具體步驟見 `docs/OWNER_ACTIONS.md`。
