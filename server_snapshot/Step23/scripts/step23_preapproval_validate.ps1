[CmdletBinding()]
param([string]$GatewayRoot="C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway",[string]$PublicBase="https://api.abutronfx.online")
$ErrorActionPreference="Stop"; $ProgressPreference="SilentlyContinue"
Write-Host "ABUTRON STEP23 PRE-APPROVAL / READ-ONLY / ZERO ORDER"
if(-not(Test-Path $GatewayRoot)){throw "GATEWAY_ROOT_NOT_FOUND"}; Write-Host "GATEWAY_ROOT=PASS"
$py="C:\Abutron\TradingPlatformV4\.venv_ctrader\Scripts\python.exe"
if(-not(Test-Path $py)){throw "CTRADER_VENV_MISSING"}; Write-Host "CTRADER_VENV=PASS"
$h=Invoke-WebRequest -Uri "$PublicBase/healthz" -UseBasicParsing -TimeoutSec 15
if($h.StatusCode -ne 200){throw "PUBLIC_TLS_HEALTH_FAIL"}; Write-Host "PUBLIC_TLS_HEALTH=PASS:200"
if(-not(Get-NetTCPConnection -State Listen -LocalPort 8091 -ErrorAction SilentlyContinue)){throw "CTRADER_8091_LISTENER=FAIL"}; Write-Host "CTRADER_8091_LISTENER=PASS"
$cb="$PublicBase/v1/ctrader/oauth/callback"
try{$r=Invoke-WebRequest -Uri $cb -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 0;$status=[int]$r.StatusCode}catch{$status=0;if($_.Exception.Response -and $_.Exception.Response.StatusCode){$status=[int]$_.Exception.Response.StatusCode}}
if($status -eq 404 -or $status -eq 0){throw "PUBLIC_OAUTH_CALLBACK_ROUTE_FAIL_STATUS=$status"}; Write-Host "PUBLIC_OAUTH_CALLBACK_ROUTE=PASS:$status"
$pre=Join-Path $GatewayRoot "scripts\preapproval_check.ps1"
if(Test-Path $pre){& $pre;if($LASTEXITCODE -ne 0){throw "STEP21A_PREAPPROVAL_CHECK_FAIL"};Write-Host "STEP21A_PREAPPROVAL_CHECK=PASS"}else{Write-Host "STEP21A_PREAPPROVAL_CHECK=SKIP_SCRIPT_NOT_FOUND"}
$envFile=Join-Path $GatewayRoot ".env"
if(Test-Path $envFile){
  $c=Get-Content $envFile -Raw
  if($c -match '(?mi)^\s*CTRADER_DEMO_EXECUTION_ENABLED\s*=\s*true\s*$'){throw 'DEMO_EXECUTION_MUST_REMAIN_FALSE'}
  if($c -match '(?mi)^\s*CTRADER_LIVE_MONEY_AUTHORIZED\s*=\s*true\s*$'){throw 'LIVE_MONEY_MUST_REMAIN_FALSE'}
  if($c -match '(?mi)^\s*CTRADER_KILL_SWITCH\s*=\s*false\s*$'){throw 'KILL_SWITCH_MUST_REMAIN_TRUE'}
  Write-Host "CTRADER_SAFETY_FLAGS=PASS"
}else{Write-Host "CTRADER_ENV=PENDING_CREDENTIAL_CONFIGURATION"}
$d=Resolve-DnsName "openapi.ctrader.com" -ErrorAction Stop | Where-Object {$_.IPAddress}; if(-not$d){throw 'CTRADER_OPENAPI_DNS_FAIL'}; Write-Host "CTRADER_OPENAPI_DNS=PASS"
$t=Test-NetConnection "openapi.ctrader.com" -Port 443 -WarningAction SilentlyContinue; if(-not$t.TcpTestSucceeded){throw 'CTRADER_OPENAPI_443_FAIL'}; Write-Host "CTRADER_OPENAPI_443=PASS"
Write-Host "STEP23_PREAPPROVAL=PASS"
Write-Host "REAL_OAUTH_AUTHORIZATION=PENDING_SPOTWARE_APPROVAL"
Write-Host "LIVE_MONEY_AUTHORIZED=False"
Write-Host "BROKER_ORDER_SENT=False"
