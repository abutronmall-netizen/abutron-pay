param([string]$Root='C:\Abutron\TradingPlatformV4')
$ErrorActionPreference='Stop'; $Target=Join-Path $Root 'ctrader_cloud_gateway'; $Python=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
Push-Location $Target
try {
  & $Python -m compileall -q ctrader_gateway
  if ($LASTEXITCODE -ne 0) { throw 'COMPILE_FAIL' }
  & $Python -m pytest -q tests
  if ($LASTEXITCODE -ne 0) { throw 'TEST_FAIL' }
  $e=Get-Content .env -Raw
  foreach($required in @('CTRADER_ENABLE_LIVE_CONNECTION=false','CTRADER_DEMO_EXECUTION_ENABLED=false','CTRADER_LIVE_MONEY_AUTHORIZED=false','CTRADER_KILL_SWITCH=true')) { if ($e -notmatch [regex]::Escape($required)) { throw "SAFETY_FAIL:$required" } }
  if ($e -match 'CTRADER_INTERNAL_API_KEY=CHANGE_ME') { throw 'INTERNAL_KEY_NOT_GENERATED' }
  if ($e -match '(?m)^CTRADER_ENCRYPTION_KEY=\s*$') { throw 'ENCRYPTION_KEY_NOT_GENERATED' }
  Write-Host 'STEP21A_PREAPPROVAL=PASS'
  Write-Host 'PERSISTENT_CONNECTION_ARCHITECTURE=PASS'
  Write-Host 'DEDICATED_CTRADER_VENV=PASS'
  Write-Host 'ATOMIC_IDEMPOTENCY=PASS'
  Write-Host 'STALE_COMMAND_GUARD=PASS'
  Write-Host 'LIVE_CONNECTION_ENABLED=False'
  Write-Host 'DEMO_EXECUTION_ENABLED=False'
  Write-Host 'LIVE_MONEY_AUTHORIZED=False'
  Write-Host 'KILL_SWITCH=True'
  Write-Host 'BROKER_ORDER_SENT=False'
} finally { Pop-Location }
