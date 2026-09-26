param([Parameter(Mandatory=$true)][int]$UserId,[Parameter(Mandatory=$true)][Int64]$AccountId)
$ErrorActionPreference='Stop'
$Root='C:\Abutron\TradingPlatformV4'; $Target=Join-Path $Root 'ctrader_cloud_gateway'
$Py=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
$EnvText=Get-Content (Join-Path $Target '.env') -Raw
if($EnvText -notmatch '(?m)^CTRADER_CLIENT_ID=\S+'){throw 'SPOTWARE_CLIENT_ID_MISSING'}
if($EnvText -notmatch '(?m)^CTRADER_CLIENT_SECRET=\S+'){throw 'SPOTWARE_CLIENT_SECRET_MISSING'}
if($EnvText -match '(?mi)^CTRADER_ENABLE_LIVE_CONNECTION\s*=\s*true\s*$'){throw 'LIVE_CONNECTION_MUST_REMAIN_FALSE'}
if($EnvText -match '(?mi)^CTRADER_LIVE_MONEY_AUTHORIZED\s*=\s*true\s*$'){throw 'LIVE_MONEY_MUST_REMAIN_FALSE'}
Push-Location $Target
try {
  & $Py .\scripts\step21d_real_recovery_cert.py --user-id $UserId --account-id $AccountId
  if($LASTEXITCODE -ne 0){throw 'STEP21D_REAL_RECOVERY_CERT_FAIL'}
} finally { Pop-Location }
