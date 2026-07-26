# GSAT_Max Closed Beta RC 驗收基準

## 狀態定義

- `PASS`：已在本機執行並驗證真實行為。
- `OWNER ACTION`：需要授權條款、外部帳號、Secret 或實機才能完成。
- 不得用 mock AI 結果標記真實 AI 為 `PASS`。

## 已驗證

- Git 安全基準與初始 RC commit：`0545dfa`。
- `flutter analyze`：PASS。
- `flutter test`：PASS，涵蓋 Router、登入恢復、Refresh 成敗、離線 session、API host、任務持久化、背景 job polling、Writing DTO、Paywall 三種結果、五分頁與小螢幕 overflow。
- `flutter build web`：PASS。
- `pytest backend/tests -q`：PASS，涵蓋 Auth rotation/revoke、Email token、Password reset、SM-2、OCR 驗證、背景 job、Writing schema、Mock Exam 防答案外洩與後端評分、AI quota、RevenueCat webhook、Migration 與 Seed 冪等。
- Alembic：空資料庫 upgrade/downgrade/re-upgrade PASS；完整既有 schema 保留資料 upgrade PASS；部分 schema 會安全拒絕。
- Seed：實際 SQLite 達到 500 vocab／50 grammar；第二次執行新增 0／0。
- Tesseract 5.5.3：使用 `backend/tests/fixtures/exam_sample.png` 真實辨識 PASS，必要英文行皆可取回。
- FastAPI 真實 HTTP：Register、Onboarding、20 字初始化、Daily Schedule、Target Date、Vocab Review、SM-2、Refresh rotation、Logout revoke PASS。

## Android 待驗收

- Android licenses：OWNER ACTION，必須由授權人閱讀並輸入 `y`。
- SDK packages、Emulator、debug APK build/install、integration test、adb logcat：等待 licenses 後執行。
- 實機相機：若 Emulator camera 不可用，列為 OWNER ACTION；相簿路徑仍須在 Emulator 驗證。
- 正式 release keystore/AAB：不屬於 debug RC，且 keystore 不得提交。

## 外部服務待驗收

- OpenAI-compatible API：OWNER ACTION。建立 `.env` 並填入 `OPENAI_API_KEY` 後執行：

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
.\.tools\flutter\bin\flutter.bat test integration_test\android_core_flow_test.dart -d emulator-5554
```
