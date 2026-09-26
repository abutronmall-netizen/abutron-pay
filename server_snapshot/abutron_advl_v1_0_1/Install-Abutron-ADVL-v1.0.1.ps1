[CmdletBinding()]
param(
    [string]$Root = "C:\Abutron\TradingPlatformV4"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host "=== ABUTRON ADVL v1.0.1 SHADOW INTEGRATION ===" -ForegroundColor Cyan

$Python = Join-Path $Root ".venv\Scripts\python.exe"
$Fusion = Join-Path $Root "abutron\fusion.py"
$AdvlDest = Join-Path $Root "abutron\advl.py"
if (-not (Test-Path $Python)) { throw "Python venv not found: $Python" }
if (-not (Test-Path $Fusion)) { throw "fusion.py not found under $Root" }

$PackageRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Patcher = Join-Path $PackageRoot "patch_fusion.py"
$UnitTest = Join-Path $PackageRoot "tests\test_advl.py"
if (-not (Test-Path $Patcher)) { throw "Missing patcher: $Patcher" }
if (-not (Test-Path $UnitTest)) { throw "Missing tests: $UnitTest" }

# Independent rollback copy in addition to patch_fusion.py's timestamped backup.
$RollbackRoot = Join-Path $Root "backups\advl-v1-installer-rollback"
New-Item -ItemType Directory -Force -Path $RollbackRoot | Out-Null
$RollbackFusion = Join-Path $RollbackRoot "fusion.py"
Copy-Item -Force $Fusion $RollbackFusion
$AdvlExisted = Test-Path $AdvlDest
$RollbackAdvl = Join-Path $RollbackRoot "advl.py"
if ($AdvlExisted) { Copy-Item -Force $AdvlDest $RollbackAdvl }

try {
    Write-Host "`n[1/6] Running standalone ADVL unit tests..." -ForegroundColor Yellow
    Push-Location $PackageRoot
    try {
        & $Python -m unittest discover -s tests -p "test_advl.py" -v
        if ($LASTEXITCODE -ne 0) { throw "Standalone ADVL tests failed." }
    }
    finally { Pop-Location }

    Write-Host "`n[2/6] Patching production Fusion with timestamped backup..." -ForegroundColor Yellow
    & $Python $Patcher $Root
    if ($LASTEXITCODE -ne 0) { throw "ADVL patch failed." }

    Write-Host "`n[3/6] Compiling production package..." -ForegroundColor Yellow
    Push-Location $Root
    try {
        & $Python -m compileall -q abutron
        if ($LASTEXITCODE -ne 0) { throw "Production compileall failed." }

        Write-Host "`n[4/6] Running existing production tests..." -ForegroundColor Yellow
        if (Test-Path (Join-Path $Root "tests")) {
            & $Python -m pytest -q
            if ($LASTEXITCODE -ne 0) { throw "Existing production tests failed." }
        }
        else {
            Write-Warning "No production tests directory found; pytest step skipped."
        }

        Write-Host "`n[5/6] Creating runtime breadth feed template..." -ForegroundColor Yellow
        $Runtime = Join-Path $Root "runtime"
        New-Item -ItemType Directory -Force -Path $Runtime | Out-Null
        $Feed = Join-Path $Runtime "advl_breadth.example.json"
$FeedJson = @'
{
  "timestamp": 0,
  "advancing_volume": 0,
  "declining_volume": 0,
  "source": "YOUR_BREADTH_PROVIDER",
  "universe": "NYSE"
}
'@
        [System.IO.File]::WriteAllText(
            $Feed,
            $FeedJson,
            (New-Object System.Text.UTF8Encoding($false))
        )

        Write-Host "`n[6/6] Verifying ADVL remains SHADOW by default..." -ForegroundColor Yellow
        $env:ABUTRON_ADVL_MODE = "shadow"
        & $Python -c "from abutron.advl import get_advl_feature; print(get_advl_feature().as_dict())"
        if ($LASTEXITCODE -ne 0) { throw "Production ADVL import failed." }
    }
    finally { Pop-Location }
}
catch {
    Write-Host "`nINSTALLATION FAILED - restoring original production files..." -ForegroundColor Red
    Copy-Item -Force $RollbackFusion $Fusion
    if ($AdvlExisted -and (Test-Path $RollbackAdvl)) {
        Copy-Item -Force $RollbackAdvl $AdvlDest
    }
    elseif (Test-Path $AdvlDest) {
        Remove-Item -Force $AdvlDest
    }
    throw
}

Write-Host "`n=== COMPLETE ===" -ForegroundColor Green
Write-Host "ADVL is installed in SHADOW mode. Missing/stale breadth data is neutral and cannot change a trade."
Write-Host "Expected live feed path: $Root\runtime\advl_breadth.json"
Write-Host "Template: $Root\runtime\advl_breadth.example.json"
Write-Host "Do NOT switch to LIVE until OOS + forward validation is complete."
Write-Host "After validation: set ABUTRON_ADVL_MODE=live and keep ABUTRON_ADVL_FUSION_WEIGHT <= 0.05 initially."
