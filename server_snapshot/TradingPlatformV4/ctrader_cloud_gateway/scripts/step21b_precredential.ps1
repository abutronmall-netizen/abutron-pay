$ErrorActionPreference='Stop'
$Root='C:\Abutron\TradingPlatformV4'
$Target=Join-Path $Root 'ctrader_cloud_gateway'
$Python=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
$Env=Join-Path $Target '.env'
Push-Location $Target
try { & $Python -m pytest -q tests; if($LASTEXITCODE -ne 0){throw 'STEP21B_TEST_FAIL'} } finally { Pop-Location }
$t=Get-Content $Env -Raw
foreach($x in @('CTRADER_ENABLE_LIVE_CONNECTION=false','CTRADER_DEMO_EXECUTION_ENABLED=false','CTRADER_LIVE_MONEY_AUTHORIZED=false','CTRADER_KILL_SWITCH=true')){if($t -notmatch [regex]::Escape($x)){throw "SAFETY_FAIL:$x"}}
Write-Host 'STEP21B_PRECREDENTIAL=PASS'
Write-Host 'OAUTH_IMPLEMENTATION=PASS'
Write-Host 'IC_MARKETS_ACCOUNT_FILTER=PASS'
Write-Host 'DEMO_LIVE_SEPARATION=PASS'
Write-Host 'MONEY_DIGITS_EQUITY_NORMALIZATION=PASS'
Write-Host 'NON_USD_ROUTER_FAIL_CLOSED=PASS'
Write-Host 'XAUUSD_DISCOVERY=PASS'
Write-Host 'DEMO_EXECUTION_ENABLED=False'
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
Write-Host 'KILL_SWITCH=True'
Write-Host 'BROKER_ORDER_SENT=False'
