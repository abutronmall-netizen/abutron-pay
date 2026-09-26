param([Parameter(Mandatory=$true)][int]$UserId,[Parameter(Mandatory=$true)][long]$AccountId,[switch]$AuthorizeDemo,[string]$Root='C:\Abutron\TradingPlatformV4')
$ErrorActionPreference='Stop'; $CorePython=Join-Path $Root '.venv\Scripts\python.exe'; $GatewayEnv=Join-Path $Root 'ctrader_cloud_gateway\.env'; $Runner=Join-Path $Root 'ctrader_cloud_gateway\scripts\step21c_real_demo_cert.py'
if(-not $AuthorizeDemo){ & $CorePython $Runner --user-id $UserId --account-id $AccountId; exit $LASTEXITCODE }
Write-Host 'STEP21C_DEMO_AUTHORIZATION=EXPLICIT'
$original=Get-Content $GatewayEnv -Raw
try {
  # This certification intentionally arms DEMO only. LIVE stays impossible.
  $armed=$original
  $armed=[regex]::Replace($armed,'(?m)^CTRADER_DEMO_EXECUTION_ENABLED=.*$','CTRADER_DEMO_EXECUTION_ENABLED=true')
  $armed=[regex]::Replace($armed,'(?m)^CTRADER_KILL_SWITCH=.*$','CTRADER_KILL_SWITCH=false')
  $armed=[regex]::Replace($armed,'(?m)^CTRADER_STEP21C_DEMO_LIFECYCLE_ENABLED=.*$','CTRADER_STEP21C_DEMO_LIFECYCLE_ENABLED=true')
  if($armed -notmatch '(?m)^CTRADER_ENABLE_LIVE_CONNECTION=false$' -or $armed -notmatch '(?m)^CTRADER_LIVE_MONEY_AUTHORIZED=false$'){throw 'LIVE_SAFETY_GATE_NOT_CLOSED'}
  Set-Content $GatewayEnv $armed -Encoding UTF8
  Write-Host 'RESTART_CTRADER_GATEWAY_REQUIRED_WITH_DEMO_CERT_GATES=TRUE'
  Write-Host 'Run start_gateway.ps1 in a separate Administrator PowerShell, then press ENTER here.'
  Read-Host | Out-Null
  & $CorePython $Runner --user-id $UserId --account-id $AccountId --authorize-demo
  $code=$LASTEXITCODE
  if($code -ne 0){throw "STEP21C_CERT_FAIL_EXIT_$code"}
}
finally { Set-Content $GatewayEnv $original -Encoding UTF8; Write-Host 'STEP21C_RUNTIME_ENV_RESTORED=TRUE'; Write-Host 'LIVE_MONEY_AUTHORIZED=False' }
