$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")
Assert-RC10Administrator

Write-Host "=== RC1-10 FINAL SECURITY / RELEASE CERTIFICATION ===" -ForegroundColor Yellow
$policy = Get-RC10Policy
$post = Get-RC10LatestFile -Directory $script:RC10Certification -Filter "RC1_10_POST_REBOOT_*.json"
if(-not $post) { throw "Post-reboot certificate missing." }
$postData = Get-Content $post.FullName -Raw | ConvertFrom-Json
if($postData.result -ne "PASS") { throw "Post-reboot certificate is not passing." }

$bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
$uptimeHours = ((Get-Date).ToUniversalTime() - $bootUtc).TotalHours
$requiredHours = [double]$policy.rdp_stability_hours
Write-Host ("UptimeHours={0:N2}" -f $uptimeHours)
Write-Host ("RequiredRdpStabilityHours={0:N2}" -f $requiredHours)
if($uptimeHours -lt $requiredHours) {
    throw ("RDP_OVERNIGHT_GATE_NOT_MATURE: uptime {0:N2}h is below required {1:N2}h." -f $uptimeHours,$requiredHours)
}

$rdpAttPath=Join-Path $script:RC10Root "rdp_stability_attestation.json"
if(-not(Test-Path $rdpAttPath)){throw "RDP stability attestation missing. Run Set-RC1-10-RdpStabilityAttestation.ps1 from the stable RDP session."}
$rdpAtt=Get-Content $rdpAttPath -Raw | ConvertFrom-Json
if($rdpAtt.pass -ne $true){throw "RDP stability attestation is not passing."}
$attBoot=[datetime]::Parse([string]$rdpAtt.boot_utc).ToUniversalTime()
if([math]::Abs(($attBoot-$bootUtc).TotalSeconds) -gt 2){throw "RDP stability attestation belongs to a different Windows boot."}

Assert-RC10ReleaseSafety | Out-Null
& (Join-Path $PSScriptRoot "Test-RC1-10-RDP.ps1") -SinceUtc $bootUtc -RequireActiveSession -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-NetworkTLS.ps1") -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-IntegrityBaseline.ps1") -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-Secrets.ps1") -FailOnBlocker

$attPath = Join-Path $script:RC10Root "release_attestation.json"
$att = Get-Content $attPath -Raw | ConvertFrom-Json
if($att.pass -ne $true) { throw "Release attestation no longer passes." }

$backupReport = Get-RC10LatestFile -Directory $script:RC10Reports -Filter "backup_restore_*.json"
if(-not $backupReport) { throw "Backup/restore report is missing." }
$backupData = Get-Content $backupReport.FullName -Raw | ConvertFrom-Json
if($backupData.result -ne "PASS") { throw "Latest backup/restore report is not PASS." }

$cert = [ordered]@{
    version="1.0.0"
    result="PASS"
    certified_utc=(Get-Date).ToUniversalTime().ToString("o")
    boot_utc=$bootUtc.ToString("o")
    uptime_hours=[math]::Round($uptimeHours,2)
    rdp_overnight_stability="PASS"
    rdp_stability_attestation="PASS"
    active_rdp_session="PASS"
    network_tls="PASS"
    integrity="PASS"
    secrets_and_rotation="PASS"
    backup_restore="PASS"
    execution_enabled=$false
    live_money_authorized=$false
    next="RC1-11 Strategy OOS / Forward Performance"
}
$path = Join-Path $script:RC10Certification ("RC1_10_FINAL_"+(Get-RC10Timestamp)+".json")
Write-RC10Json -Path $path -Object $cert

Write-Host "RC1_10_CERTIFIED=True" -ForegroundColor Green
Write-Host "RC1-10 — Security / Release Audit CERTIFIED" -ForegroundColor Green
Write-Host "CERTIFICATION=$path"
Write-Host "NEXT=RC1-11 Strategy OOS / Forward Performance" -ForegroundColor Yellow
