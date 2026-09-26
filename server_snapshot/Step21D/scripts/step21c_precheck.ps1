param([string]$Root='C:\Abutron\TradingPlatformV4')
$ErrorActionPreference='Stop'
$Target=Join-Path $Root 'ctrader_cloud_gateway'; $Python=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
Push-Location $Target
try { & $Python -m pytest -q tests; if($LASTEXITCODE -ne 0){throw 'STEP21C_STATIC_FAIL'} } finally { Pop-Location }
$envFile=Join-Path $Target '.env'; $g=Get-Content $envFile -Raw
foreach($x in @('CTRADER_ENABLE_LIVE_CONNECTION=false','CTRADER_DEMO_EXECUTION_ENABLED=false','CTRADER_LIVE_MONEY_AUTHORIZED=false','CTRADER_KILL_SWITCH=true','CTRADER_STEP21C_DEMO_LIFECYCLE_ENABLED=false')){if($g -notmatch [regex]::Escape($x)){throw "STEP21C_SAFETY_FAIL:$x"}}
Write-Host 'STEP21C_BUILD_PRECERT=PASS'; Write-Host 'STEP21C_REAL_OAUTH_REQUIRED=TRUE'; Write-Host 'STEP21C_DEMO_LIFECYCLE_ENABLED=False'; Write-Host 'LIVE_MONEY_AUTHORIZED=False'; Write-Host 'BROKER_ORDER_SENT=False'
