param(
    [string]$Root = "C:\Abutron\TradingPlatformV4"
)
$ErrorActionPreference = "Stop"
$Python = Join-Path $Root ".venv\Scripts\python.exe"
$Collector = Join-Path $Root "tools\advl_dxfeed\advl_dxfeed_collector.py"
$EnvFile = Join-Path $Root "secrets\dxfeed_advl.env"

Write-Host "=== ABUTRON ADVL dxFeed ONE-SHOT VALIDATION ===" -ForegroundColor Cyan
if (-not (Test-Path $Python)) { throw "Python not found: $Python" }
if (-not (Test-Path $Collector)) { throw "Collector not found: $Collector" }
if (-not (Test-Path $EnvFile)) { throw "Config not found: $EnvFile" }

& $Python $Collector --root $Root --env $EnvFile --validate-only
if ($LASTEXITCODE -ne 0) { throw "dxFeed one-shot validation failed." }

Write-Host "VALIDATION=PASS" -ForegroundColor Green
Write-Host "No production feed write occurred because --validate-only was used."
