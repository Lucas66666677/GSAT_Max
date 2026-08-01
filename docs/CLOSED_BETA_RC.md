# GSAT_Max Closed Beta RC 驗收基準

## 狀態定義

- `PASS`：已在本機執行並驗證真實行為。
- `OWNER ACTION`：需要授權條款、外部帳號、Secret 或實機才能完成。
- 不得用 mock AI 結果標記真實 AI 為 `PASS`。

## 已驗證

- Git 安全基準與初始 RC commit：`0545dfa`；本輪功能與驗收證據會以獨立 RC commit 收錄，尚不建立 release tag。
- `flutter analyze`：PASS。
- `flutter test`：23 tests PASS，新增短時段排程、正回饋與紙本包資料契約，並持續涵蓋 Router、登入恢復、Refresh 成敗、離線 session、API host、任務持久化、SyncQueue、背景 job、Writing、Paywall、五分頁與小螢幕 overflow。
- `flutter build web`：PASS。
- `pytest backend/tests -q`：27 tests PASS，新增 3/10/20/45 分鐘預算、微型勝利、點數冪等、完成任務保留、五日 PDF 紙本包、完成碼、Gemini/Groq fallback 與 PII 遮蔽。PDF 使用內附 Noto Sans TC 字形嵌入，7 頁 A4 實際渲染與繁中版面檢查 PASS。
- Alembic：新 head `9c52b7f79fd4`；空資料庫 upgrade/downgrade PASS，baseline 既有資料安全升級 PASS，真實專案 DB 已升級。
- Seed：實際 SQLite 為 513 vocab／50 grammar；連續兩次執行皆新增 0／0。
- Tesseract 5.5.3：使用 `backend/tests/fixtures/exam_sample.png` 真實辨識 PASS，必要英文行皆可取回。
- FastAPI 真實 HTTP：Register、Onboarding、20 字初始化、Daily Schedule、Target Date、Vocab Review、SM-2、Refresh rotation、Logout revoke PASS。

## Android 待驗收

- Project-local JDK 17 與官方 Android command-line tools 已完成，Flutter 已設定 SDK/JDK 路徑。
- Android licenses：OWNER ACTION，必須由授權人閱讀並輸入 `y`；Platform 36、Build Tools 36、NDK 28.2 與 Platform Tools 會在授權後安裝。
- Emulator、debug APK build/install、integration test、adb logcat：等待 licenses 與 SDK packages 後執行。
- 實機相機：若 Emulator camera 不可用，列為 OWNER ACTION；相簿路徑仍須在 Emulator 驗證。
- 正式 release keystore/AAB：不屬於 debug RC，且 keystore 不得提交。

## 外部服務待驗收

- AI provider：OWNER ACTION。Router 已支援 `Gemini -> Groq -> OpenAI -> Ollama` 自動 fallback；建立 `.env` 並至少填入 `GEMINI_API_KEY`、`GROQ_API_KEY` 或 `OPENAI_API_KEY` 後執行：

  ```powershell
  .\scripts\verify_real_ai.ps1
  ```

  腳本會驗證 mnemonic、Grammar、Writing structured grading、OCR error analysis、Full Mock generation/grading；只在 `artifacts/verification/` 保存去識別化摘要。

- RevenueCat：OWNER ACTION。需要正式 public SDK key、產品 Offering、商店 sandbox 帳號與 webhook Secret。
- Email provider：OWNER ACTION。development provider 已驗證 token 流程，正式寄信供應商尚未設定。
- 正式 HTTPS API host：OWNER ACTION。實機 Closed Beta 不可使用 Emulator 專用 `10.0.2.2`。

## 可重跑命令

```powershell
.\.venv\Scripts\python.exe -m pytest backend/tests -q
.\.tools\flutter\bin\flutter.bat pub get
.\.tools\flutter\bin\flutter.bat analyze
.\.tools\flutter\bin\flutter.bat test
.\.tools\flutter\bin\flutter.bat build web
```

Android licenses 完成後：

```powershell
$env:JAVA_HOME=(Resolve-Path '.\.tools\jdk17').Path
$env:ANDROID_SDK_ROOT=(Resolve-Path '.\.tools\android-sdk').Path
.\.tools\flutter\bin\flutter.bat doctor -v
.\.tools\flutter\bin\flutter.bat build apk --debug
.\.tools\flutter\bin\flutter.bat test integration_test\android_core_flow_test.dart -d emulator-5554 --dart-define=GSAT_MAX_DISABLE_PERMISSION_PROMPTS=true
```
