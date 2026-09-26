[CmdletBinding()]
param([string]$GatewayRoot="C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway")
$ErrorActionPreference="Stop"
$envFile=Join-Path $GatewayRoot ".env"; if(-not(Test-Path $envFile)){throw 'CTRADER_ENV_MISSING'}
$c=Get-Content $envFile -Raw
foreach($k in @('CTRADER_CLIENT_ID','CTRADER_CLIENT_SECRET','CTRADER_REDIRECT_URI')){if($c -notmatch "(?m)^\s*$k\s*=\s*\S+"){throw "MISSING_REQUIRED_ENV=$k"}}
if($c -notmatch '(?m)^\s*CTRADER_REDIRECT_URI\s*=\s*https://api\.abutronfx\.online/v1/ctrader/oauth/callback\s*$'){throw 'REDIRECT_URI_NOT_PRODUCTION_CALLBACK'}
if($c -match '(?mi)^\s*CTRADER_DEMO_EXECUTION_ENABLED\s*=\s*true\s*$'){throw 'DEMO_EXECUTION_MUST_REMAIN_DISABLED'}
if($c -match '(?mi)^\s*CTRADER_LIVE_MONEY_AUTHORIZED\s*=\s*true\s*$'){throw 'LIVE_MONEY_MUST_REMAIN_DISABLED'}
if($c -match '(?mi)^\s*CTRADER_KILL_SWITCH\s*=\s*false\s*$'){throw 'KILL_SWITCH_MUST_REMAIN_ENABLED'}
$r=Join-Path $GatewayRoot 'scripts\readiness_after_credentials.ps1'; if(-not(Test-Path $r)){throw 'READINESS_SCRIPT_MISSING'}
& $r; if($LASTEXITCODE -ne 0){throw 'READINESS_AFTER_CREDENTIALS_FAIL'}
Write-Host 'STEP23_CREDENTIAL_READINESS=PASS'
Write-Host 'OAUTH_SCOPE=trading'
Write-Host 'NEXT=BEGIN_REAL_OAUTH_AUTHORIZATION'
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
Write-Host 'BROKER_ORDER_SENT=False'
