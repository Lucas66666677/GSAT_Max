param(
    [string]$ApiBaseUrl = '/api',
    [ValidateSet('development', 'production')]
    [string]$Environment = 'production'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$projectFlutter = Join-Path $projectRoot '.tools\flutter\bin\flutter.bat'
$flutter = if (Test-Path -LiteralPath $projectFlutter) {
    $projectFlutter
} else {
    (Get-Command flutter -ErrorAction Stop).Source
}

if ($Environment -eq 'production' -and
    -not $ApiBaseUrl.StartsWith('/') -and
    -not $ApiBaseUrl.StartsWith('https://')) {
    throw 'Production API_BASE_URL must be HTTPS or a same-origin path such as /api.'
}

Push-Location $projectRoot
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
    & $flutter build web --release `
        "--dart-define=APP_ENV=$Environment" `
        "--dart-define=API_BASE_URL=$ApiBaseUrl"
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Web release build failed.' }
    Write-Host "Website ready: $projectRoot\build\web" -ForegroundColor Green
} finally {
    Pop-Location
}
