param(
    [string]$JarvisRoot = "C:\Abutron\Jarvis",
    [switch]$Activate
)

$ErrorActionPreference = "Stop"

$packageRoot = Split-Path -Parent $PSScriptRoot
$python = Join-Path $JarvisRoot ".venv\Scripts\python.exe"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $JarvisRoot "backups\phase-2-1-$stamp"

if (-not (Test-Path $python)) {
    throw "Jarvis Python not found: $python"
}

New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $JarvisRoot "app\monitoring") -Force | Out-Null

$filesToBackup = @(
    "app\api\main.py",
    "app\api\system_health.py",
    "app\monitoring\__init__.py",
    "app\monitoring\config.py",
    "app\monitoring\models.py",
    "app\monitoring\metrics.py",
    "app\monitoring\collectors.py",
    "app\monitoring\service.py",
    "tests\test_phase_2_1_health.py"
)

foreach ($rel in $filesToBackup) {
    $src = Join-Path $JarvisRoot $rel
    if (Test-Path $src) {
        $dst = Join-Path $backupRoot $rel
        New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
        Copy-Item $src $dst -Force
    }
}

Write-Host "Backup: $backupRoot"

Copy-Item (Join-Path $packageRoot "app\monitoring\*") (Join-Path $JarvisRoot "app\monitoring") -Force
Copy-Item (Join-Path $packageRoot "app\api\system_health.py") (Join-Path $JarvisRoot "app\api\system_health.py") -Force
Copy-Item (Join-Path $packageRoot "tests\test_phase_2_1_health.py") (Join-Path $JarvisRoot "tests\test_phase_2_1_health.py") -Force

$mainFile = Join-Path $JarvisRoot "app\api\main.py"

$patch = @'
from pathlib import Path

p = Path(r"C:\Abutron\Jarvis\app\api\main.py")
s = p.read_text(encoding="utf-8")

import_line = "from app.api.system_health import router as system_health_router\n"
include_line = "app.include_router(system_health_router)\n"

if import_line not in s:
    anchors = [
        "from app.api.intelligence import router as intelligence_router\n",
        "from app.integrations.whatsapp.webhook import router as whatsapp_router\n",
    ]
    for anchor in anchors:
        if anchor in s:
            s = s.replace(anchor, anchor + import_line, 1)
            break
    else:
        raise RuntimeError("No safe import anchor found in app/api/main.py")

if include_line not in s:
    anchors = [
        "app.include_router(intelligence_router)\n",
        "app.include_router(whatsapp_router)\n",
    ]
    for anchor in anchors:
        if anchor in s:
            s = s.replace(anchor, anchor + include_line, 1)
            break
    else:
        raise RuntimeError("No safe router anchor found in app/api/main.py")

p.write_text(s, encoding="utf-8", newline="\n")
print("MAIN_PATCH=PASS")
'@

$patch = $patch.Replace('C:\Abutron\Jarvis', $JarvisRoot.Replace('\','\\'))
$patch | & $python -
if ($LASTEXITCODE -ne 0) { throw "main.py patch failed" }

Push-Location $JarvisRoot
try {
    & $python -m compileall -q app
    if ($LASTEXITCODE -ne 0) { throw "compileall failed" }

    & $python -m pytest -q
    if ($LASTEXITCODE -ne 0) { throw "pytest failed" }
}
finally {
    Pop-Location
}

Write-Host "PHASE_2_1_BUILD_TESTS=PASS"

if ($Activate) {
    Write-Host "Restarting only Abutron-Jarvis scheduled task..."
    Stop-ScheduledTask -TaskName "Abutron-Jarvis" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName "Abutron-Jarvis"

    $ready = $false
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $h = Invoke-RestMethod -Uri "http://127.0.0.1:8787/health" -TimeoutSec 3
            if ($h.status -in @("ok", "degraded")) {
                $ready = $true
                break
            }
        }
        catch {}
        Start-Sleep -Seconds 1
    }
    if (-not $ready) { throw "Jarvis did not recover after activation" }
    Write-Host "JARVIS_ACTIVATION=PASS"
}
else {
    Write-Host "Activation skipped. Re-run with -Activate when ready."
}

Write-Host "PHASE_2_1_INSTALL=PASS"
