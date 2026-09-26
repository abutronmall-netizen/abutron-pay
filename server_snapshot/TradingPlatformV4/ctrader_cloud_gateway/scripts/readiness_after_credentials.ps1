param([string]$Root='C:\Abutron\TradingPlatformV4')
$ErrorActionPreference='Stop'
$Target=Join-Path $Root 'ctrader_cloud_gateway'
$envText=Get-Content (Join-Path $Target '.env') -Raw
if ($envText -match '(?m)^CTRADER_CLIENT_ID=\s*$' -or $envText -match '(?m)^CTRADER_CLIENT_SECRET=\s*$') { throw 'SPOTWARE_CREDENTIALS_MISSING' }
& (Join-Path $Target 'scripts\start_gateway.ps1') -Root $Root
$deadline=(Get-Date).AddSeconds(35)
do {
  Start-Sleep -Seconds 2
  $h=Invoke-RestMethod 'http://127.0.0.1:8091/health'
  $demoReady=$false
  if ($h.workers -and $h.workers.DEMO) { $demoReady=[bool]$h.workers.DEMO.app_authorized }
} while (-not $demoReady -and (Get-Date) -lt $deadline)
$h | ConvertTo-Json -Depth 8
if (-not $demoReady) { throw 'CTRADER_DEMO_WORKER_APP_AUTH_NOT_READY' }
if ($h.live_money_authorized -ne $false) { throw 'LIVE_MONEY_LOCK_FAIL' }
if ($h.demo_execution_enabled -ne $false) { throw 'DEMO_EXECUTION_MUST_STILL_BE_OFF' }
if ($h.live_connection_enabled -ne $false) { throw 'LIVE_CONNECTION_MUST_STILL_BE_OFF' }
if ($h.kill_switch -ne $true) { throw 'KILL_SWITCH_MUST_STILL_BE_ON' }
Write-Host 'STEP21A_CREDENTIAL_READINESS=PASS'
Write-Host 'CTRADER_DEMO_APP_AUTH=PASS'
Write-Host 'BROKER_ORDER_SENT=False'
Write-Host 'NEXT=STEP21B_OAUTH_AND_DEMO_ACCOUNT_DISCOVERY'
