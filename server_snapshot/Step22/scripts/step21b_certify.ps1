param([Parameter(Mandatory=$true)][string]$UserId,[Int64]$AccountId=0)
$ErrorActionPreference='Stop'
$Root='C:\Abutron\TradingPlatformV4'
$Target=Join-Path $Root 'ctrader_cloud_gateway'
$Env=Join-Path $Target '.env'
if(-not(Test-Path $Env)){throw 'CTRADER_ENV_MISSING'}
$lines=Get-Content $Env
function Val($name){$x=$lines|Where-Object{$_ -match ('^'+[regex]::Escape($name)+'=')}|Select-Object -First 1;if(-not$x){return ''};return $x.Substring($x.IndexOf('=')+1)}
$key=Val 'CTRADER_INTERNAL_API_KEY'; $cid=Val 'CTRADER_CLIENT_ID'; $sec=Val 'CTRADER_CLIENT_SECRET'
if(-not $cid -or -not $sec){throw 'SPOTWARE_CREDENTIALS_MISSING'}
if((Val 'CTRADER_ENABLE_LIVE_CONNECTION') -ne 'false'){throw 'LIVE_CONNECTION_MUST_REMAIN_OFF'}
if((Val 'CTRADER_DEMO_EXECUTION_ENABLED') -ne 'false'){throw 'DEMO_EXECUTION_MUST_REMAIN_OFF'}
if((Val 'CTRADER_LIVE_MONEY_AUTHORIZED') -ne 'false'){throw 'LIVE_MONEY_MUST_REMAIN_OFF'}
if((Val 'CTRADER_KILL_SWITCH') -ne 'true'){throw 'KILL_SWITCH_MUST_REMAIN_ON'}
$h=@{'X-Abutron-Internal-Key'=$key}
$health=Invoke-RestMethod -Method Get -Uri 'http://127.0.0.1:8091/health'
if(-not $health.credentials_configured){throw 'CTRADER_CREDENTIALS_NOT_ACTIVE'}
if(-not $health.workers.DEMO.connected -or -not $health.workers.DEMO.app_authorized){throw 'CTRADER_DEMO_WORKER_NOT_READY'}
$refresh=Invoke-RestMethod -Method Post -Headers $h -Uri ("http://127.0.0.1:8091/v1/ctrader/users/"+$UserId+"/accounts/refresh")
$demo=@($refresh.accounts|Where-Object{$_.environment -eq 'DEMO'})
if($demo.Count -lt 1){throw 'NO_IC_MARKETS_DEMO_ACCOUNT_DISCOVERED'}
if($AccountId -eq 0){$AccountId=[Int64]$demo[0].ctid_account_id}
if(-not($demo|Where-Object{[Int64]$_.ctid_account_id -eq $AccountId})){throw 'REQUESTED_DEMO_ACCOUNT_NOT_DISCOVERED'}
$d=Invoke-RestMethod -Method Get -Headers $h -Uri ("http://127.0.0.1:8091/v1/ctrader/users/"+$UserId+"/accounts/"+$AccountId+"/discovery")
if(-not $d.zero_order){throw 'ZERO_ORDER_ATTESTATION_FAIL'}
if($d.environment -ne 'DEMO'){throw 'NOT_DEMO'}
if($d.symbol.canonical -ne 'XAUUSD' -or $d.symbol.symbol_id -le 0){throw 'XAUUSD_DISCOVERY_FAIL'}
if($d.execution.demo_execution_enabled -or $d.execution.live_money_authorized -or -not $d.execution.kill_switch){throw 'EXECUTION_SAFETY_FAIL'}
Write-Host 'STEP21B_OAUTH_ACCOUNT_DISCOVERY=PASS'
Write-Host ('BROKER='+$d.broker_title)
Write-Host ('ENVIRONMENT='+$d.environment)
Write-Host ('DEPOSIT_CURRENCY='+$d.deposit_currency)
Write-Host ('BALANCE='+$d.account.balance)
Write-Host ('EQUITY='+$d.account.equity)
Write-Host ('EQUITY_ROUTE='+$d.equity_route)
Write-Host ('XAUUSD_SYMBOL_ID='+$d.symbol.symbol_id)
Write-Host ('XAUUSD_MIN_VOLUME='+$d.symbol.min_volume)
Write-Host ('XAUUSD_STEP_VOLUME='+$d.symbol.step_volume)
Write-Host ('XAUUSD_MAX_VOLUME='+$d.symbol.max_volume)
if(-not $d.router_currency_ready){Write-Host 'EQUITY_ROUTER_CURRENCY_GATE=BLOCKED_NON_USD'}else{Write-Host 'EQUITY_ROUTER_CURRENCY_GATE=PASS'}
Write-Host 'DEMO_EXECUTION_ENABLED=False'
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
Write-Host 'KILL_SWITCH=True'
Write-Host 'BROKER_ORDER_SENT=False'
