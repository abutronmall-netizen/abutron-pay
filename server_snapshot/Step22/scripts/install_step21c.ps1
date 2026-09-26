param([string]$Root='C:\Abutron\TradingPlatformV4')
$ErrorActionPreference='Stop'; $Source=Split-Path -Parent $PSScriptRoot; $Target=Join-Path $Root 'ctrader_cloud_gateway'; $Python=Join-Path $Root '.venv_ctrader\Scripts\python.exe'; $CorePython=Join-Path $Root '.venv\Scripts\python.exe'; $GatewayEnv=Join-Path $Target '.env'
if(-not(Test-Path $Target)){throw 'STEP21B_TARGET_MISSING'}; if(-not(Test-Path $GatewayEnv)){throw 'STEP21B_ENV_MISSING'}
Write-Host '===================================================='; Write-Host ' ABUTRON STEP 21C v1.2.0 - cTRADER DEMO LIFECYCLE'; Write-Host ' BUILD/PRECERT ONLY - LIVE MONEY REMAINS DISABLED'; Write-Host '===================================================='
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'; $backup=Join-Path $Root ("backups\step21c_"+$stamp); New-Item -ItemType Directory -Force -Path $backup|Out-Null
Copy-Item $Target (Join-Path $backup 'ctrader_cloud_gateway') -Recurse -Force
$api=Join-Path $Root 'abutron\api.py'; $service=Join-Path $Root 'abutron\service.py'; Copy-Item $api (Join-Path $backup 'api.py') -Force; Copy-Item $service (Join-Path $backup 'service.py') -Force
try {
  $tempEnv=Join-Path $env:TEMP ("ctrader_env_"+[guid]::NewGuid()+'.tmp'); Copy-Item $GatewayEnv $tempEnv -Force
  $tempDb=$null; $db=Join-Path $Target 'data\ctrader_gateway.db'; if(Test-Path $db){$tempDb=Join-Path $env:TEMP ("ctrader_db_"+[guid]::NewGuid()+'.db'); Copy-Item $db $tempDb -Force}
  foreach($name in @('ctrader_gateway','core_integration','requirements.txt','.env.example','README.md','MANIFEST.json','STEP21C_BUILD_REPORT.json','docs','tests','deployment','scripts')){ $src=Join-Path $Source $name; if(-not(Test-Path $src)){throw "SOURCE_ARTIFACT_MISSING:$name"}; Copy-Item $src $Target -Recurse -Force }
  Copy-Item $tempEnv $GatewayEnv -Force; Remove-Item $tempEnv -Force; if($tempDb){New-Item -ItemType Directory -Force -Path (Split-Path $db -Parent)|Out-Null; Copy-Item $tempDb $db -Force; Remove-Item $tempDb -Force}
  # append new Step21C defaults to preserved env if missing; never arm execution.
  $g=Get-Content $GatewayEnv -Raw
  foreach($line in @('CTRADER_STEP21C_DEMO_LIFECYCLE_ENABLED=false','CTRADER_STEP21C_REQUIRE_REAL_OAUTH_PASS=true','CTRADER_STEP21C_SPOT_MAX_AGE_SECONDS=10','CTRADER_STEP21C_RECONCILE_TIMEOUT_SECONDS=15')){ $k=$line.Split('=')[0]; if($g -notmatch "(?m)^$k="){$g += "`r`n$line"} }
  Set-Content $GatewayEnv $g -Encoding UTF8
  Push-Location $Target; try { & $Python -m compileall -q ctrader_gateway core_integration; if($LASTEXITCODE -ne 0){throw 'STEP21C_COMPILE_FAIL'}; & $Python -m pytest -q tests; if($LASTEXITCODE -ne 0){throw 'STEP21C_TEST_FAIL'} } finally {Pop-Location}
  # Install additive core customer adapter, not a global execution switch.
  New-Item -ItemType Directory -Force -Path (Join-Path $Root 'abutron\gateways')|Out-Null
  Copy-Item (Join-Path $Target 'core_integration\ctrader_cloud.py') (Join-Path $Root 'abutron\gateways\ctrader_cloud.py') -Force
  Copy-Item (Join-Path $Target 'core_integration\volume.py') (Join-Path $Root 'abutron\gateways\ctrader_volume.py') -Force
  Copy-Item (Join-Path $Target 'core_integration\ctrader_customer_pipeline.py') (Join-Path $Root 'abutron\ctrader_customer_pipeline.py') -Force
  Push-Location $Root; try { & $CorePython -m py_compile (Join-Path $Root 'abutron\gateways\ctrader_cloud.py') (Join-Path $Root 'abutron\gateways\ctrader_volume.py') (Join-Path $Root 'abutron\ctrader_customer_pipeline.py'); if($LASTEXITCODE -ne 0){throw 'STEP21C_CORE_ADAPTER_COMPILE_FAIL'} } finally {Pop-Location}
  $svc=Get-Content $service -Raw; if($svc -notmatch 'self\.gateway\s*=\s*MT5Gateway\(\)'){throw 'STEP21C_GLOBAL_EXECUTION_PATH_CHANGED'}
  $g=Get-Content $GatewayEnv -Raw; foreach($x in @('CTRADER_ENABLE_LIVE_CONNECTION=false','CTRADER_DEMO_EXECUTION_ENABLED=false','CTRADER_LIVE_MONEY_AUTHORIZED=false','CTRADER_KILL_SWITCH=true','CTRADER_STEP21C_DEMO_LIFECYCLE_ENABLED=false')){if($g -notmatch [regex]::Escape($x)){throw "STEP21C_SAFETY_GATE_FAIL:$x"}}
  Write-Host 'STEP21C_INSTALL=PASS'; Write-Host 'CUSTOMER_CTRADER_ACCOUNT_STATE_ADAPTER=PASS'; Write-Host 'CUSTOMER_CTRADER_SPOT_ADAPTER=PASS'; Write-Host 'MARKET_ORDER_RELATIVE_PROTECTION_FIX=PASS'; Write-Host 'NO_WORSENING_SL_GUARD=PASS'; Write-Host 'STEP21B_REAL_OAUTH_REQUIRED=TRUE'; Write-Host 'Kronos_TradingService_EXECUTION_PATH_CHANGED=False'; Write-Host 'DEMO_EXECUTION_ENABLED=False'; Write-Host 'LIVE_MONEY_AUTHORIZED=False'; Write-Host 'KILL_SWITCH=True'; Write-Host 'BROKER_ORDER_SENT=False'; Write-Host 'NEXT=RUN_STEP21C_PRECHECK'
}
catch { Write-Host 'STEP21C_INSTALL_FAIL_ROLLBACK=START'; Remove-Item $Target -Recurse -Force; Copy-Item (Join-Path $backup 'ctrader_cloud_gateway') $Target -Recurse -Force; Copy-Item (Join-Path $backup 'api.py') $api -Force; Copy-Item (Join-Path $backup 'service.py') $service -Force; Write-Host 'STEP21C_INSTALL_FAIL_ROLLBACK=PASS'; throw }
