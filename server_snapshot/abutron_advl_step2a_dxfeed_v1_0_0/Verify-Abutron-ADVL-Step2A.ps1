param(
    [string]$Root = "C:\Abutron\TradingPlatformV4"
)
$ErrorActionPreference = "Stop"
$Python = Join-Path $Root ".venv\Scripts\python.exe"
$Verifier = Join-Path $Root "tools\advl_dxfeed\verify_advl_pipeline.py"

Write-Host "=== ABUTRON ADVL STEP 2A PIPELINE VERIFY ===" -ForegroundColor Cyan
& $Python $Verifier --root $Root
if ($LASTEXITCODE -ne 0) { throw "ADVL Step 2A pipeline verification failed." }
Write-Host "VERIFY=PASS" -ForegroundColor Green
