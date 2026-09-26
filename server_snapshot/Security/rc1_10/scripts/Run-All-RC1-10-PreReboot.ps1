$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

Write-Host "=== RC1-10 PRE-REBOOT SECURITY GATE ===" -ForegroundColor Yellow

& (Join-Path $PSScriptRoot "Invoke-RC1-10-PreflightAudit.ps1") -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-Secrets.ps1") -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-NetworkTLS.ps1") -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-RDP.ps1") -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-BackupRestore.ps1") -FailOnBlocker
& (Join-Path $PSScriptRoot "Test-RC1-10-MicrosoftBaselineReadiness.ps1")
& (Join-Path $PSScriptRoot "New-RC1-10-IntegrityBaseline.ps1")
& (Join-Path $PSScriptRoot "Test-RC1-10-IntegrityBaseline.ps1") -FailOnBlocker

Write-Host "RC1_10_ALL_PRE_REBOOT_TESTS=PASS" -ForegroundColor Green
Write-Host "NEXT=Certify-RC1-10-PreReboot.ps1" -ForegroundColor Yellow
