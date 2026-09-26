param(
    [string]$JarvisRoot = "C:\Abutron\Jarvis"
)

$ErrorActionPreference = "Stop"

$PackageRoot = Split-Path $PSScriptRoot -Parent
$Python = Join-Path $JarvisRoot ".venv\Scripts\python.exe"

if (!(Test-Path $JarvisRoot)) { throw "Jarvis root not found: $JarvisRoot" }
if (!(Test-Path $Python)) { throw "Jarvis Python not found: $Python" }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $JarvisRoot "backups\phase-2-1-passive-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

$files = @(
    "app\monitoring\config.py",
    "app\monitoring\collectors.py",
    "tests\test_phase_2_1_health.py"
)

foreach ($rel in $files) {
    $src = Join-Path $PackageRoot $rel
    $dst = Join-Path $JarvisRoot $rel
    $bak = Join-Path $backup $rel

    if (!(Test-Path $src)) { throw "Patch source missing: $src" }
    if (Test-Path $dst) {
        New-Item -ItemType Directory -Force -Path (Split-Path $bak -Parent) | Out-Null
        Copy-Item $dst $bak -Force
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
    Copy-Item $src $dst -Force
}

Write-Host "Backup: $backup"

Push-Location $JarvisRoot
try {
    & $Python -m compileall -q app tests
    if ($LASTEXITCODE -ne 0) { throw "compileall failed" }

    & $Python -m pytest -q
    if ($LASTEXITCODE -ne 0) { throw "pytest failed" }
}
finally {
    Pop-Location
}

Write-Host "PHASE_2_1_PASSIVE_PATCH_TESTS=PASS"
Write-Host "NO SERVICE RESTART PERFORMED"
Write-Host "PHASE_2_1_PASSIVE_PATCH=PASS"
