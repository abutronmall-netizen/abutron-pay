$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")
Assert-RC10Administrator

Assert-RC10ReleaseSafety | Out-Null

$attPath = Join-Path $script:RC10Root "release_attestation.json"
if(-not(Test-Path $attPath)) { throw "Release attestation missing." }
$att = Get-Content $attPath -Raw | ConvertFrom-Json
if($att.pass -ne $true) { throw "Release attestation is not passing." }

# Run the complete gate again so the certificate reflects current state.
& (Join-Path $PSScriptRoot "Run-All-RC1-10-PreReboot.ps1")

$cert = [ordered]@{
    version="1.0.0"
    result="PASS"
    certified_utc=(Get-Date).ToUniversalTime().ToString("o")
    boot_utc=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")
    execution_enabled=$false
    live_money_authorized=$false
    rc1_08="OBSERVE_ONLY"
    rc1_09="NOTIFY_ONLY_TELEGRAM"
    firewall_or_rdp_auto_changes=$false
    next_gate="CLEAN_WINDOWS_REBOOT"
}
$path = Join-Path $script:RC10Certification ("RC1_10_PRE_REBOOT_"+(Get-RC10Timestamp)+".json")
Write-RC10Json -Path $path -Object $cert
Write-Host "PRE_REBOOT_CERTIFIED=True" -ForegroundColor Green
Write-Host "CERTIFICATION=$path"
Write-Host "NEXT=Restart-Computer, reconnect by RDP, then run Certify-RC1-10-PostReboot.ps1" -ForegroundColor Yellow
