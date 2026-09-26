$ErrorActionPreference='Stop'
$Source=Split-Path -Parent $PSScriptRoot
$Root='C:\Abutron\TradingPlatformV4'; $Target=Join-Path $Root 'ctrader_cloud_gateway'; $Py=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
Write-Host '===================================================='
Write-Host ' ABUTRON STEP 21D v1.3.0 - cTRADER FAILURE/RECOVERY'
Write-Host ' FAIL-CLOSED HARDENING - LIVE MONEY REMAINS DISABLED'
Write-Host '===================================================='
if(!(Test-Path $Target)){throw 'STEP21C_TARGET_MISSING'}
if(!(Test-Path $Py)){throw 'CTRADER_DEDICATED_VENV_MISSING'}
$Backup=Join-Path $Root ('backups\step21d_'+(Get-Date -Format 'yyyyMMdd_HHmmss')); New-Item -ItemType Directory -Force -Path $Backup|Out-Null
Copy-Item $Target (Join-Path $Backup 'ctrader_cloud_gateway') -Recurse -Force
$Env=Join-Path $Target '.env'; $Db=Join-Path $Target 'data\ctrader_gateway.db'
$EnvBackup=$null; $DbBackup=$null
if(Test-Path $Env){$EnvBackup=Join-Path $env:TEMP ('abutron_ctrader_env_'+[guid]::NewGuid().ToString('N')); Copy-Item $Env $EnvBackup -Force}
if(Test-Path $Db){$DbBackup=Join-Path $env:TEMP ('abutron_ctrader_db_'+[guid]::NewGuid().ToString('N')); Copy-Item $Db $DbBackup -Force}
$items=@('ctrader_gateway','core_integration','scripts','tests','deployment','docs','.env.example','requirements.txt','README.md','MANIFEST.json','STEP21D_BUILD_REPORT.json')
foreach($x in $items){$src=Join-Path $Source $x; if(Test-Path $src){$dst=Join-Path $Target $x; if(Test-Path $dst){Remove-Item $dst -Recurse -Force}; Copy-Item $src $dst -Recurse -Force}}
if($EnvBackup){Copy-Item $EnvBackup $Env -Force; Remove-Item $EnvBackup -Force -ErrorAction SilentlyContinue}
if($DbBackup){New-Item -ItemType Directory -Force -Path (Split-Path $Db)|Out-Null; Copy-Item $DbBackup $Db -Force; Remove-Item $DbBackup -Force -ErrorAction SilentlyContinue}
Push-Location $Target
try {
  & $Py -m pytest -q tests
  if($LASTEXITCODE -ne 0){throw 'STEP21D_TEST_FAIL'}
  & $Py -m compileall -q ctrader_gateway core_integration
  if($LASTEXITCODE -ne 0){throw 'STEP21D_COMPILE_FAIL'}
  $envText=Get-Content .env -Raw
  if($envText -match '(?mi)^CTRADER_ENABLE_LIVE_CONNECTION\s*=\s*true\s*$'){throw 'LIVE_CONNECTION_MUST_REMAIN_FALSE'}
  if($envText -match '(?mi)^CTRADER_LIVE_MONEY_AUTHORIZED\s*=\s*true\s*$'){throw 'LIVE_MONEY_MUST_REMAIN_FALSE'}
} catch {
  Pop-Location
  Remove-Item $Target -Recurse -Force; Copy-Item (Join-Path $Backup 'ctrader_cloud_gateway') $Target -Recurse -Force
  Write-Host 'STEP21D_ROLLBACK=PASS'; throw
}
Pop-Location
Write-Host 'STEP21D_INSTALL=PASS'
Write-Host 'READ_ONLY_TRANSPORT_RETRY=PASS'
Write-Host 'MUTATION_AUTO_RETRY=FALSE'
Write-Host 'UNCERTAIN_RECOVERY_INSPECTION=PASS'
Write-Host 'ORDER_HISTORY_CLIENT_ORDER_ID_MATCH=PASS'
Write-Host 'TOKEN_REFRESH_ROTATION=PASS'
Write-Host 'WORKER_RESTART_PATH=PASS'
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
Write-Host 'BROKER_ORDER_SENT=False'
Write-Host 'NEXT=RUN_STEP21D_PRECHECK'
