$ErrorActionPreference='Stop'
$Root='C:\Abutron\TradingPlatformV4'; $Target=Join-Path $Root 'ctrader_cloud_gateway'; $Py=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
Write-Host '===================================================='
Write-Host ' ABUTRON STEP 22 - PRODUCTION PERIMETER PRECHECK'
Write-Host ' NO TRADING STATE CHANGES'
Write-Host '===================================================='
Push-Location $Target
try {
  & $Py -m pytest -q tests
  if($LASTEXITCODE -ne 0){throw 'STEP22_TEST_FAIL'}
  & $Py -m compileall -q ctrader_gateway core_integration ops
  if($LASTEXITCODE -ne 0){throw 'STEP22_COMPILE_FAIL'}
} finally {Pop-Location}
& (Join-Path $Target 'ops\step22_secret_audit.ps1') -Root $Root
if($LASTEXITCODE -ne 0){throw 'STEP22_SECRET_AUDIT_FAIL'}
& (Join-Path $Target 'ops\step22_service_inventory.ps1') -Root $Root
if($LASTEXITCODE -ne 0){throw 'STEP22_INVENTORY_FAIL'}
Write-Host 'CTRADER_DB_MAY_BE_DEFERRED_BEFORE_REAL_OAUTH=TRUE'
& (Join-Path $Target 'ops\step22_backup.ps1') -Root $Root
if($LASTEXITCODE -ne 0){throw 'STEP22_BACKUP_DRILL_FAIL'}
& (Join-Path $Target 'ops\step22_monitor.ps1') -Root $Root
if($LASTEXITCODE -ne 0){throw 'STEP22_MONITOR_FAIL'}
Write-Host 'STEP22_BUILD_PRECERT=PASS'
Write-Host 'PUBLIC_TLS_APPLY=OPERATOR_ACTION_REQUIRED'
Write-Host 'STEP21B_REAL_OAUTH_REQUIRED=TRUE'
Write-Host 'STEP21C_REAL_DEMO_REQUIRED=TRUE'
Write-Host 'STEP21D_REAL_NETWORK_CERT_REQUIRED=TRUE'
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
Write-Host 'BROKER_ORDER_SENT=False'
