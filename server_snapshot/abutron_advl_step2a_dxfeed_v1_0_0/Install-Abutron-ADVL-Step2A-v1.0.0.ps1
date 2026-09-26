param(
    [string]$Root = "C:\Abutron\TradingPlatformV4"
)

$ErrorActionPreference = "Stop"
Write-Host "=== ABUTRON ADVL STEP 2A dxFeed COLLECTOR v1.0.0 ===" -ForegroundColor Cyan

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Python = Join-Path $Root ".venv\Scripts\python.exe"
$Target = Join-Path $Root "tools\advl_dxfeed"
$Secrets = Join-Path $Root "secrets"
$Runtime = Join-Path $Root "runtime"
$EnvFile = Join-Path $Secrets "dxfeed_advl.env"

if (-not (Test-Path $Root)) { throw "Root not found: $Root" }
if (-not (Test-Path $Python)) { throw "Python not found: $Python" }

Write-Host "[1/7] Creating directories..."
New-Item -ItemType Directory -Force -Path $Target, $Secrets, $Runtime | Out-Null

Write-Host "[2/7] Installing collector files..."
Copy-Item (Join-Path $Here "advl_dxfeed_collector.py") (Join-Path $Target "advl_dxfeed_collector.py") -Force
Copy-Item (Join-Path $Here "Register-Abutron-ADVL-dxFeed-Task.ps1") (Join-Path $Target "Register-Abutron-ADVL-dxFeed-Task.ps1") -Force
Copy-Item (Join-Path $Here "Test-Abutron-ADVL-dxFeed.ps1") (Join-Path $Target "Test-Abutron-ADVL-dxFeed.ps1") -Force
Copy-Item (Join-Path $Here "Get-Abutron-ADVL-dxFeed-Health.ps1") (Join-Path $Target "Get-Abutron-ADVL-dxFeed-Health.ps1") -Force
Copy-Item (Join-Path $Here "verify_advl_pipeline.py") (Join-Path $Target "verify_advl_pipeline.py") -Force
Copy-Item (Join-Path $Here "Verify-Abutron-ADVL-Step2A.ps1") (Join-Path $Target "Verify-Abutron-ADVL-Step2A.ps1") -Force

Write-Host "[3/7] Creating secrets template if missing..."
if (-not (Test-Path $EnvFile)) {
    Copy-Item (Join-Path $Here "dxfeed_advl.env.example") $EnvFile -Force
    Write-Host "Created: $EnvFile"
} else {
    Write-Host "Keeping existing config: $EnvFile"
}

Write-Host "[4/7] Locking secrets file ACL..."
& icacls $EnvFile /inheritance:r | Out-Null
& icacls $EnvFile /grant:r "SYSTEM:F" "Administrators:F" | Out-Null

Write-Host "[5/7] Running unit tests..."
& $Python -m unittest discover -s (Join-Path $Here "tests") -p "test_*.py" -v
if ($LASTEXITCODE -ne 0) { throw "Step 2A unit tests failed." }

Write-Host "[6/7] Running collector self-test..."
& $Python (Join-Path $Target "advl_dxfeed_collector.py") --root $Root --self-test
if ($LASTEXITCODE -ne 0) { throw "Collector self-test failed." }

Write-Host "[7/7] Compiling collector..."
& $Python -m py_compile (Join-Path $Target "advl_dxfeed_collector.py")
if ($LASTEXITCODE -ne 0) { throw "Collector compile failed." }

Write-Host ""
Write-Host "=== INSTALL COMPLETE ===" -ForegroundColor Green
Write-Host "Collector: $Target\advl_dxfeed_collector.py"
Write-Host "Config:    $EnvFile"
Write-Host ""
Write-Host "NEXT: Edit dxfeed_advl.env with production endpoint/token, then run:"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Target\Test-Abutron-ADVL-dxFeed.ps1`" -Root `"$Root`""
Write-Host ""
Write-Host "The installer does NOT start the collector and does NOT enable ADVL LIVE mode."
