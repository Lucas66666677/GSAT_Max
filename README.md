# GSAT Max by Lucirel

GSAT Max 是 Lucirel 面向台灣高中生打造的學測英文訓練系統。同一套 Flutter 前端同時交付 Android、iOS 與可安裝的 Web/PWA；後端使用 FastAPI、SQLAlchemy 與 SQLite。手機、iPad 與桌機網頁共用帳號、學習進度與 AI 功能。

## 已驗證環境

- Python 3.11
- Flutter 3.44.7 / Dart 3.12.2
- Chrome Web release build
- Responsive Web release：手機單欄、iPad 雙欄、桌機側邊導覽與三欄功能區
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
AI_PROVIDER_ORDER=gemini,groq,openai,ollama
GEMINI_API_KEY=
GEMINI_MODEL=gemini-2.5-flash
GROQ_API_KEY=
GROQ_MODEL=openai/gpt-oss-20b
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

### 免費 AI 路由

後端所有文字生成共用同一個 provider router，預設順序是 `Gemini -> Groq -> OpenAI -> Ollama`。前一個服務遇到 timeout、429 或 5xx 時會自動嘗試下一個，回傳的 `performance_metrics` 也會標記實際使用的 provider 與 model。

- `GEMINI_API_KEY`：預設 `gemini-2.5-flash`，支援文字與圖片，適合作為免費層主力。
- `GROQ_API_KEY`：預設 `openai/gpt-oss-20b`，適合低延遲文字生成與 Gemini 限額後的 fallback。
- `OPENAI_API_KEY`：付費備援；未填寫就自動略過。
- `OLLAMA_BASE_URL`：本機最終備援，不需 API Key，但主機必須已啟動 Ollama 並下載指定模型。

API Key 只放在後端 `.env`，Flutter App 不保存第三方 AI Secret。`AI_REDACT_STUDENT_PII=true` 會在送出文字前遮蔽常見 Email、手機、身分證字號與姓名欄位。免費雲端方案的資料使用條款與速率限制可能變動，Closed Beta 前仍需在各供應商後台確認未成年學生資料政策。

### 短時段與紙本學習

- Home 可依當下可用的 `3 / 10 / 20 / 45` 分鐘即時重排，第一個任務固定是高成功率的微型勝利。
- 完成任務、單字複習與紙本日會累積成長點、等級、本週活躍天數與溫和連續學習保護卡；所有計分事件皆使用 idempotency key，離線重送不會重複加分。
- Settings 可保存平日／週末預算、偏好衝刺時間、每週目標與溫和 streak。
- Profile 可生成五日 A4 紙本學習包，含單字、文法、短篇閱讀、答案頁、完成碼及家長／老師簽名區；回到 App 後可回填完成天數並同步點數。

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

## Web 網站開發與佈署

開發時可用上方 `flutter run -d chrome`。產出可佈署網站：

```powershell
.\scripts\build_web.ps1 -ApiBaseUrl /api -Environment production
```

產物在 `build/web`，內含 PWA manifest、SEO metadata、robots 與靜態安全 header。Web 版 PDF 直接使用瀏覽器原生下載，不會呼叫行動平台的檔案 API。

本機同時啟動前後端：

```powershell
.\scripts\start_full_stack.ps1
```

生產環境可使用根目錄 `compose.yaml`，Nginx 提供 SPA/PWA 並將同源 `/api` 反向代理到 FastAPI，避免 CORS 與 mixed-content 問題：

```powershell
docker compose up --build -d
```

完整 HTTPS、domain、reverse proxy 與環境變數說明見 `docs/WEB_DEPLOYMENT.md`。

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

佈署前另外執行 Release Preflight，檢查生產設定形狀、資料庫遷移狀態、後端健康契約與前端對後端的 URL 接線。此工具不讀取任何密鑰內容、不連線正式資料庫、不變更佈署；資料庫遷移會在暫存目錄的拋棄式 SQLite 上實際執行 `upgrade head` 與 `downgrade base`，並逐欄比對 ORM 模型：

```powershell
.\.venv\Scripts\python.exe -m backend.release_preflight --env-file .env.example
.\.venv\Scripts\python.exe -m backend.release_preflight --from-environ `
  --frontend-origin https://gsat-max.example.com
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
- `lib/core/services/file_download_service*.dart`：Web/行動平台 PDF 下載與開啟
- `backend/main.py`：API、認證、AI、背景工作與資料流程
- `backend/models.py`：SQLAlchemy 模型
- `backend/seed_data.py`：可重複執行的 GSAT Seed CLI
- `backend/release_preflight.py`：不接觸密鑰的佈署前檢查 CLI
- `backend/tests/`、`test/`：後端與 Flutter 自動化測試
- `docs/`：執行計畫、驗證紀錄與 Owner Actions
- `deploy/`、`compose.yaml`：Web Nginx + FastAPI 的生產容器化佈署

## 外部服務

RevenueCat 商品、商店帳號、正式 Email Provider、AI Key、HTTPS 主機與正式品牌素材仍需由 Owner 在外部後台完成。具體步驟見 `docs/OWNER_ACTIONS.md`。
