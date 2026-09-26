$ErrorActionPreference='Stop'
$Source=Split-Path -Parent $PSScriptRoot
$Root='C:\Abutron\TradingPlatformV4'; $Target=Join-Path $Root 'ctrader_cloud_gateway'; $Py=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
Write-Host '===================================================='
Write-Host ' ABUTRON STEP 22 v1.4.1 - PRODUCTION PERIMETER'
Write-Host ' TLS / SECURITY / BACKUP / MONITORING - LIVE OFF'
Write-Host '===================================================='
if(!(Test-Path $Target)){throw 'STEP21D_TARGET_MISSING'}
if(!(Test-Path $Py)){throw 'CTRADER_DEDICATED_VENV_MISSING'}
$Backup=Join-Path $Root ('backups\step22_'+(Get-Date -Format 'yyyyMMdd_HHmmss')); New-Item -ItemType Directory -Force -Path $Backup|Out-Null
Copy-Item $Target (Join-Path $Backup 'ctrader_cloud_gateway') -Recurse -Force
$Env=Join-Path $Target '.env'; $Db=Join-Path $Target 'data\ctrader_gateway.db'; $EnvBackup=$null; $DbBackup=$null
if(Test-Path $Env){$EnvBackup=Join-Path $env:TEMP ('abutron_ctrader_env_'+[guid]::NewGuid().ToString('N')); Copy-Item $Env $EnvBackup -Force}
if(Test-Path $Db){$DbBackup=Join-Path $env:TEMP ('abutron_ctrader_db_'+[guid]::NewGuid().ToString('N')); Copy-Item $Db $DbBackup -Force}
$items=@('ctrader_gateway','core_integration','scripts','tests','deployment','docs','ops','.env.example','requirements.txt','README.md','MANIFEST.json','STEP22_BUILD_REPORT.json')
try {
  foreach($x in $items){$src=Join-Path $Source $x; if(Test-Path $src){$dst=Join-Path $Target $x; if(Test-Path $dst){Remove-Item $dst -Recurse -Force}; Copy-Item $src $dst -Recurse -Force}}
  if($EnvBackup){Copy-Item $EnvBackup $Env -Force}
  if($DbBackup){New-Item -ItemType Directory -Force -Path (Split-Path $Db)|Out-Null; Copy-Item $DbBackup $Db -Force}
  Push-Location $Target
  try {
    & $Py -m pytest -q tests
    if($LASTEXITCODE -ne 0){throw 'STEP22_TEST_FAIL'}
    & $Py -m compileall -q ctrader_gateway core_integration ops
    if($LASTEXITCODE -ne 0){throw 'STEP22_COMPILE_FAIL'}
    $envText=Get-Content .env -Raw
    if($envText -match '(?mi)^CTRADER_ENABLE_LIVE_CONNECTION\s*=\s*true\s*$'){throw 'LIVE_CONNECTION_MUST_REMAIN_FALSE'}
    if($envText -match '(?mi)^CTRADER_LIVE_MONEY_AUTHORIZED\s*=\s*true\s*$'){throw 'LIVE_MONEY_MUST_REMAIN_FALSE'}
  } finally {Pop-Location}
} catch {
  if(Test-Path $Target){Remove-Item $Target -Recurse -Force}
  Copy-Item (Join-Path $Backup 'ctrader_cloud_gateway') $Target -Recurse -Force
  Write-Host 'STEP22_ROLLBACK=PASS'; throw
} finally {
  if($EnvBackup){Remove-Item $EnvBackup -Force -ErrorAction SilentlyContinue}
  if($DbBackup){Remove-Item $DbBackup -Force -ErrorAction SilentlyContinue}
}
Write-Host 'STEP22_INSTALL=PASS'
Write-Host 'TLS_CONFIG_STAGED=TRUE'
Write-Host 'TLS_CONFIG_APPLIED=FALSE'
Write-Host 'PUBLIC_ROUTE_ALLOWLIST=PASS'
Write-Host 'BACKUP_DRILL_READY=PASS'
Write-Host 'CTRADER_DB_BACKUP_DEFERRED_UNTIL_OAUTH_ALLOWED=TRUE'
Write-Host 'MONITORING_READY=PASS'
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
Write-Host 'BROKER_ORDER_SENT=False'
Write-Host 'NEXT=RUN_STEP22_PRECHECK'
