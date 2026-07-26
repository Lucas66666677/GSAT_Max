param(
    [string]$ApiBase = "http://127.0.0.1:8000",
    [string]$SummaryPath = "artifacts/verification/real_ai_summary.json",
    [switch]$SkipFullMock
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$EnvPath = Join-Path $ProjectRoot ".env"
$FixturePath = Join-Path $ProjectRoot "backend/tests/fixtures/exam_sample.png"
$SummaryFile = Join-Path $ProjectRoot $SummaryPath
$StartedBackend = $null
$Summary = [ordered]@{
    verified_at_utc = [DateTime]::UtcNow.ToString("o")
    api_base = $ApiBase
    real_ai = $true
    checks = [ordered]@{}
}

function Get-MetricSummary($Response) {
    $metrics = $Response.performance_metrics
    if ($null -eq $metrics) {
        return $null
    }
    return [ordered]@{
        total_time_seconds = [double]$metrics.total_time_seconds
        tokens_per_second = [double]$metrics.tokens_per_second
        total_tokens = [int]$metrics.total_tokens
        cached = [bool]$metrics.cached
    }
}

function Invoke-JsonApi {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Method,
        [object]$Body,
        [hashtable]$Headers = @{}
    )
    $params = @{
        Uri = "$ApiBase$Path"
        Method = $Method
        Headers = $Headers
        TimeoutSec = 180
    }
    if ($null -ne $Body) {
        $params.ContentType = "application/json"
        $params.Body = $Body | ConvertTo-Json -Depth 30 -Compress
    }
    return Invoke-RestMethod @params
}

function Wait-BackgroundJob {
    param(
        [Parameter(Mandatory = $true)][string]$JobId,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [int]$MaxPolls = 90
    )
    for ($poll = 0; $poll -lt $MaxPolls; $poll++) {
        $job = Invoke-JsonApi -Path "/jobs/$JobId" -Method "GET" -Headers $Headers
        if ($job.status -eq "completed") {
            return $job
        }
        if ($job.status -eq "failed") {
            throw "Background job failed: $($job.error_message)"
        }
        Start-Sleep -Seconds 3
    }
    throw "Background job $JobId did not complete before the verification timeout."
}

if (-not (Test-Path -LiteralPath $EnvPath)) {
    throw "Missing .env. Create it from .env.example and set OPENAI_API_KEY before real AI verification."
}
$keyLine = Get-Content -LiteralPath $EnvPath | Where-Object {
    $_ -match '^\s*OPENAI_API_KEY\s*='
} | Select-Object -Last 1
$keyValue = if ($keyLine) { ($keyLine -split '=', 2)[1].Trim().Trim('"').Trim("'") } else { "" }
if ([string]::IsNullOrWhiteSpace($keyValue) -or $keyValue -match 'replace|your[-_ ]?key|example') {
    throw "OPENAI_API_KEY is empty or still a placeholder. No real AI checks were run."
}
if (-not (Test-Path -LiteralPath $FixturePath)) {
    throw "OCR fixture is missing: $FixturePath"
}

try {
    try {
        $health = Invoke-RestMethod -Uri "$ApiBase/health" -TimeoutSec 5
    }
    catch {
        if ($ApiBase -ne "http://127.0.0.1:8000") {
            throw
        }
        $python = Join-Path $ProjectRoot ".venv/Scripts/python.exe"
        if (-not (Test-Path -LiteralPath $python)) {
            throw "Backend is offline and .venv/Scripts/python.exe was not found."
        }
        $logDirectory = Join-Path $ProjectRoot "artifacts/verification"
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $StartedBackend = Start-Process -FilePath $python `
            -ArgumentList "-m", "uvicorn", "backend.main:app", "--host", "127.0.0.1", "--port", "8000" `
            -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput (Join-Path $logDirectory "backend.stdout.log") `
            -RedirectStandardError (Join-Path $logDirectory "backend.stderr.log")
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            Start-Sleep -Milliseconds 500
            try {
                $health = Invoke-RestMethod -Uri "$ApiBase/health" -TimeoutSec 3
                break
            }
            catch {
                if ($StartedBackend.HasExited) {
                    throw "Verification backend exited during startup."
                }
            }
        }
    }
    if (-not [bool]$health.openai_configured) {
        throw "Backend health reports openai_configured=false. Restart it after updating .env."
    }

    $email = "real-ai-verify-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())@example.com"
    $password = "VerifyAI-$(Get-Random)-Pass!"
    $auth = Invoke-JsonApi -Path "/auth/register" -Method "POST" -Body @{
        email = $email
        password = $password
        display_name = "RC Verifier"
    }
    $headers = @{ Authorization = "Bearer $($auth.access_token)" }

    $mnemonic = Invoke-JsonApi -Path "/generate/vocab-mnemonic" -Method "POST" -Headers $headers -Body @{
        word = "meticulous"
        definition = "very careful and precise"
        app_mode = "focus"
    }
    $Summary.checks.mnemonic = [ordered]@{
        passed = -not [string]::IsNullOrWhiteSpace([string]$mnemonic.etymology)
        has_taiwanese_mnemonic = -not [string]::IsNullOrWhiteSpace([string]$mnemonic.taiwanese_mnemonic)
        metrics = Get-MetricSummary $mnemonic
    }

    $grammar = Invoke-JsonApi -Path "/generate/grammar" -Method "POST" -Headers $headers -Body @{
        mode = "quiz"
        sentence = "Test inversion at authentic GSAT difficulty."
        app_mode = "focus"
    }
    $Summary.checks.grammar = [ordered]@{
        passed = ($grammar.options.Count -eq 4 -and $grammar.correct_option_index -ge 0 -and $grammar.correct_option_index -lt 4)
        option_count = $grammar.options.Count
        has_explanation = -not [string]::IsNullOrWhiteSpace([string]$grammar.explanation)
        metrics = Get-MetricSummary $grammar
    }

    $writing = Invoke-JsonApi -Path "/evaluate/writing" -Method "POST" -Headers $headers -Body @{
        essay_type = "standard"
        essay = "Technology can improve education when students use it with clear goals. It provides quick access to information and allows learners to practice at their own pace. However, students must still evaluate sources carefully and discuss difficult ideas with teachers. Therefore, technology should support thoughtful learning instead of replacing it."
        app_mode = "focus"
    }
    $Summary.checks.writing = [ordered]@{
        passed = ($writing.evaluation.total_score -ge 0 -and $writing.evaluation.total_score -le 20)
        total_score = [double]$writing.evaluation.total_score
        correction_count = @($writing.evaluation.corrections).Count
        rubric_version = [string]$writing.evaluation.rubric_version
        metrics = Get-MetricSummary $writing
    }

    $ocr = Invoke-RestMethod -Uri "$ApiBase/upload/exam" -Method "POST" -Headers $headers -TimeoutSec 240 -Form @{
        exam_image = Get-Item -LiteralPath $FixturePath
        app_mode = "focus"
    }
    $ocrJobStatus = [string]$ocr.expansion_job_status
    if ($ocr.expansion_job_id) {
        $ocrJob = Wait-BackgroundJob -JobId $ocr.expansion_job_id -Headers $headers -MaxPolls 60
        $ocrJobStatus = [string]$ocrJob.status
    }
    $Summary.checks.ocr = [ordered]@{
        passed = ($ocr.extracted_text.Length -gt 40 -and $null -ne $ocr.corrected_mistakes)
        extracted_character_count = $ocr.extracted_text.Length
        corrected_mistake_count = @($ocr.corrected_mistakes).Count
        expansion_job_status = $ocrJobStatus
        metrics = Get-MetricSummary $ocr
    }

    if (-not $SkipFullMock) {
        $queuedExam = Invoke-JsonApi -Path "/generate/full-mock-exam/jobs" -Method "POST" -Headers $headers -Body @{
            difficulty = "GSAT"
            version = "real-ai-rc-v1"
            force_refresh = $false
            app_mode = "focus"
        }
        $examJob = Wait-BackgroundJob -JobId $queuedExam.id -Headers $headers -MaxPolls 120
        $exam = $examJob.result
        $questionCount = 0
        foreach ($section in $exam.sections) {
            $questionCount += @($section.questions).Count
        }
        $grading = Invoke-JsonApi -Path "/evaluate/full-mock-exam" -Method "POST" -Headers $headers -Body @{
            exam_id = $exam.exam_id
            selected_answers = @{}
            translation_answer = "Students should verify information before sharing it."
            essay_answer = "Practice under time pressure helps students notice weak points. A useful plan combines review, reading, and careful reflection. After each test, students should examine their mistakes and decide what to practice next. This process makes improvement measurable and keeps preparation focused."
            app_mode = "focus"
        }
        $Summary.checks.full_mock_exam = [ordered]@{
            passed = ($questionCount -eq 56 -and $grading.total_score -ge 0 -and $grading.total_score -le 100)
            question_count = $questionCount
            generation_job_status = [string]$examJob.status
            total_score = [double]$grading.total_score
            metrics = Get-MetricSummary $grading
        }
    }
    else {
        $Summary.checks.full_mock_exam = [ordered]@{
            passed = $false
            skipped = $true
            reason = "Explicitly skipped by operator."
        }
    }

    $failedChecks = @($Summary.checks.GetEnumerator() | Where-Object {
        -not [bool]$_.Value.passed
    })
    $Summary.overall_passed = ($failedChecks.Count -eq 0)
}
catch {
    $Summary.overall_passed = $false
    $Summary.failure = [ordered]@{
        type = $_.Exception.GetType().FullName
        message = ($_.Exception.Message -replace $keyValue, "[REDACTED]")
    }
    throw
}
finally {
    $summaryDirectory = Split-Path -Parent $SummaryFile
    New-Item -ItemType Directory -Path $summaryDirectory -Force | Out-Null
    $Summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $SummaryFile -Encoding UTF8
    if ($StartedBackend -and -not $StartedBackend.HasExited) {
        Stop-Process -Id $StartedBackend.Id -Force
    }
}

if (-not $Summary.overall_passed) {
    throw "One or more real AI checks failed. See the de-identified summary."
}
Write-Host "Real AI verification passed. Summary: $SummaryFile"
