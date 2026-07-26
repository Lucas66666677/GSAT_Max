param(
    [switch]$SkipInstall,
    [int]$Port = 8000
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$venvPython = Join-Path $projectRoot '.venv\Scripts\python.exe'

if (-not (Test-Path -LiteralPath $venvPython)) {
    python -m venv (Join-Path $projectRoot '.venv')
}

if (-not $SkipInstall) {
    & $venvPython -m pip install --upgrade pip
    & $venvPython -m pip install -r (Join-Path $projectRoot 'requirements.txt')
}

Push-Location $projectRoot
try {
    & $venvPython -m uvicorn backend.main:app --host 0.0.0.0 --port $Port --reload
} finally {
    Pop-Location
}
