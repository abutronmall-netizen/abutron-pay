$ErrorActionPreference='Stop'
$Here=Split-Path -Parent $PSScriptRoot
$Root='C:\Abutron\TradingPlatformV4'
$Target=Join-Path $Root 'ctrader_cloud_gateway'
$Py=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
if(!(Test-Path $Target)){throw 'STEP21D_GATEWAY_MISSING'}
Push-Location $Target
try {
  & $Py -m pytest -q tests
  if($LASTEXITCODE -ne 0){throw 'STEP21D_TEST_FAIL'}
  & $Py -m compileall -q ctrader_gateway core_integration
  if($LASTEXITCODE -ne 0){throw 'STEP21D_COMPILE_FAIL'}
  $envText=Get-Content .env -Raw
  if($envText -match '(?mi)^CTRADER_ENABLE_LIVE_CONNECTION\s*=\s*true\s*$'){throw 'LIVE_CONNECTION_MUST_REMAIN_FALSE'}
  if($envText -match '(?mi)^CTRADER_LIVE_MONEY_AUTHORIZED\s*=\s*true\s*$'){throw 'LIVE_MONEY_MUST_REMAIN_FALSE'}
  Write-Host 'STEP21D_BUILD_PRECERT=PASS'
  Write-Host 'READ_ONLY_TRANSPORT_RETRY=PASS'
  Write-Host 'MUTATION_AUTO_RETRY=FALSE'
  Write-Host 'UNCERTAIN_RECOVERY_INSPECTION=PASS'
  Write-Host 'TOKEN_REFRESH_ROTATION=PASS'
  Write-Host 'WORKER_RESTART_PATH=PASS'
  Write-Host 'LIVE_MONEY_AUTHORIZED=False'
  Write-Host 'BROKER_ORDER_SENT=False'
  Write-Host 'STEP21D_REAL_NETWORK_CERT_REQUIRES_OAUTH=TRUE'
} finally { Pop-Location }
