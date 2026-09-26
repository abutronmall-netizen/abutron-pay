param([switch]$RequireTelegram=$true,[switch]$RequireWhatsApp=$true)
$ErrorActionPreference="Stop"
Write-Host "=== RC1-09 FINAL POST-REBOOT CERTIFICATION ===" -ForegroundColor Yellow
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
$engine="C:\Abutron\Jarvis\rc1_09\rc1_09\engine.py"
if(-not(Test-Path $engine)){throw "RC1-09 engine missing"}
$deploy=(Get-Item $engine).LastWriteTimeUtc
Write-Host "DeploymentUTC=$($deploy.ToString('o'))"
Write-Host "BootUTC=$($boot.ToString('o'))"
if($boot -le $deploy){throw "NO_REBOOT_AFTER_RC1_09_INSTALL"}

foreach($t in @("Abutron-Jarvis","Abutron-Jarvis-RC1-08","Abutron-Jarvis-RC1-09","Abutron-Prometheus")){
  $x=Get-ScheduledTask -TaskName $t -ErrorAction Stop
  if($x.State -ne "Running"){throw "$t not Running"}
}
$h=Invoke-RestMethod "http://127.0.0.1:8789/health" -TimeoutSec 10
if($h.status -ne "ok" -or $h.mode -ne "NOTIFY_ONLY" -or $h.actions_enabled -ne $false -or -not $h.rc1_08_ok){
  throw "RC1-09 health/safety gate failed"
}
if($RequireTelegram -and -not $h.channels.telegram){throw "Telegram not configured"}
if($RequireWhatsApp -and -not $h.channels.whatsapp){throw "WhatsApp not configured"}
Write-Host "PASS services persisted; RC1-09 NOTIFY_ONLY / actions disabled" -ForegroundColor Green

$testScript=Join-Path $PSScriptRoot "Test-RC1-09-Transports.ps1"
$args=@{}
if($RequireTelegram){$args["Telegram"]=$true}
if($RequireWhatsApp){$args["WhatsApp"]=$true}
& $testScript @args

# RC1-08 must remain healthy.
$r8=Invoke-RestMethod "http://127.0.0.1:8788/health"
if($r8.status -ne "ok" -or $r8.mode -ne "OBSERVE_ONLY"){throw "RC1-08 regression"}
$core=Invoke-RestMethod "http://127.0.0.1:8088/health"
if($core.execution_enabled -ne $false -or $core.mt5.live_trading -ne $false){throw "SAFETY FAIL live trading enabled"}

$certDir="C:\Abutron\Jarvis\certification\rc1_09"; New-Item -ItemType Directory -Force $certDir | Out-Null
$stamp=Get-Date -Format "yyyyMMdd-HHmmss"
$cert=[ordered]@{
 version="1.0.0"; result="PASS"; certified_utc=(Get-Date).ToUniversalTime().ToString("o");
 boot_utc=$boot.ToString("o"); mode=$h.mode; actions_enabled=$h.actions_enabled;
 telegram=[bool]$h.channels.telegram; whatsapp=[bool]$h.channels.whatsapp;
 rc1_08_healthy=$true; live_money_authorized=$false
}
$path=Join-Path $certDir "RC1_09_CERTIFICATION_$stamp.json"
$cert | ConvertTo-Json | Set-Content $path -Encoding UTF8
Write-Host "RC1_09_CERTIFIED=True" -ForegroundColor Green
Write-Host "RC1-09 — Telegram + WhatsApp / Meta Alerts CERTIFIED" -ForegroundColor Green
Write-Host "CERTIFICATION=$path"
Write-Host "NEXT=RC1-10 Security / Release Audit" -ForegroundColor Yellow
