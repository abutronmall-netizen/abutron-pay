$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")
Assert-RC10Administrator

Write-Host "=== RC1-10 POST-REBOOT SECURITY CERTIFICATION ===" -ForegroundColor Yellow
$pre = Get-RC10LatestFile -Directory $script:RC10Certification -Filter "RC1_10_PRE_REBOOT_*.json"
if(-not $pre) { throw "Pre-reboot certificate missing." }
$preData = Get-Content $pre.FullName -Raw | ConvertFrom-Json
$preUtc = [datetime]::Parse([string]$preData.certified_utc).ToUniversalTime()
$bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
Write-Host "PreCertUTC=$($preUtc.ToString('o'))"
Write-Host "BootUTC=$($bootUtc.ToString('o'))"
if($bootUtc -le $preUtc) { throw "NO_REBOOT_AFTER_RC1_10_PRE_CERT" }

Assert-RC10ReleaseSafety | Out-Null

foreach($name in @("Abutron-Jarvis","Abutron-Jarvis-RC1-08","Abutron-Jarvis-RC1-09","Abutron-Prometheus")) {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction Stop
    if($t.State -ne "Running") { throw "$name is not Running after reboot." }
}
Write-Host "PASS critical Jarvis/monitoring tasks persisted" -ForegroundColor Green

& (Join-Path $PSScriptRoot "Test-RC1-10-NetworkTLS.ps1") -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-RDP.ps1") -SinceUtc $preUtc -RequireActiveSession -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-IntegrityBaseline.ps1") -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-Secrets.ps1") -FailOnBlocker

$cert = [ordered]@{
    version="1.0.0"
    result="PASS"
    certified_utc=(Get-Date).ToUniversalTime().ToString("o")
    pre_certified_utc=$preUtc.ToString("o")
    boot_utc=$bootUtc.ToString("o")
    active_rdp_reconnect_verified=$true
    clean_reboot_verified=$true
    integrity_verified=$true
    live_money_authorized=$false
    final_overnight_rdp_gate="PENDING"
}
$path = Join-Path $script:RC10Certification ("RC1_10_POST_REBOOT_"+(Get-RC10Timestamp)+".json")
Write-RC10Json -Path $path -Object $cert
Write-Host "POST_REBOOT_CERTIFIED=True" -ForegroundColor Green
Write-Host "CERTIFICATION=$path"
Write-Host "FINAL_RDP_STABILITY_GATE=PENDING" -ForegroundColor Yellow
Write-Host "NEXT=After the server has remained up through the normal overnight window, run Certify-RC1-10-Final.ps1" -ForegroundColor Yellow
