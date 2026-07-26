param(
    [int]$Vocab = 500,
    [int]$Grammar = 50,
    [switch]$OfflineFallback
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$venvPython = Join-Path $projectRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython)) {
    throw 'Run scripts/start_backend.ps1 once to create the virtual environment.'
}

$arguments = @(
    (Join-Path $projectRoot 'backend\seed_data.py'),
    '--vocab', $Vocab,
    '--grammar', $Grammar,
    '--database-url', "sqlite:///$((Join-Path $projectRoot 'backend\gsat_english.db').Replace('\', '/'))"
)
if ($OfflineFallback) {
    $arguments += '--offline-fallback'
}
& $venvPython @arguments
