param([switch]$Detached)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker Desktop is required for the one-command website stack.'
}

Push-Location $projectRoot
try {
    $arguments = @('compose', 'up', '--build')
    if ($Detached) { $arguments += '-d' }
    & docker @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Docker Compose failed.' }
    if ($Detached) {
        Write-Host 'GSAT_Max website: http://localhost:8080' -ForegroundColor Green
        Write-Host 'FastAPI docs: http://localhost:8000/docs' -ForegroundColor Green
    }
} finally {
    Pop-Location
}
