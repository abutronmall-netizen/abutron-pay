$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

Write-Host "=== ABUTRON RC1-10 SECURITY / RELEASE AUDIT v1.0.1 ===" -ForegroundColor Yellow

$PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Common = Join-Path $PackageRoot "lib\RC1-10.Common.ps1"
. $Common

Assert-RC10Administrator
$state = Assert-RC10ReleaseSafety
Write-Host "PASS release safety: execution OFF / RC1-08 OBSERVE_ONLY / RC1-09 NOTIFY_ONLY" -ForegroundColor Green

$Dest = "C:\Abutron\Security\rc1_10"
$dirs = @(
    $Dest,
    (Join-Path $Dest "lib"),
    (Join-Path $Dest "config"),
    (Join-Path $Dest "scripts"),
    (Join-Path $Dest "docs"),
    (Join-Path $Dest "reports"),
    (Join-Path $Dest "backups"),
    (Join-Path $Dest "integrity"),
    (Join-Path $Dest "certification")
)
foreach($d in $dirs) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

Copy-Item (Join-Path $PackageRoot "lib\*") (Join-Path $Dest "lib") -Force
Copy-Item (Join-Path $PackageRoot "config\*") (Join-Path $Dest "config") -Force
Copy-Item (Join-Path $PackageRoot "scripts\*") (Join-Path $Dest "scripts") -Force
Copy-Item (Join-Path $PackageRoot "docs\*") (Join-Path $Dest "docs") -Force

# RC1-10 evidence, backup and integrity material can contain sensitive metadata.
# Restrict the entire RC1-10 tree to local Administrators and SYSTEM.
& icacls $Dest /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null
if($LASTEXITCODE -ne 0) { throw "Failed to apply RC1-10 directory ACL." }

$deployment = [ordered]@{
    version = "1.0.1"
    installed_utc = (Get-Date).ToUniversalTime().ToString("o")
    boot_utc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString("o")
    mode = "AUDIT_FAIL_CLOSED"
    changes_to_trading = $false
    rdp_changed = $false
    firewall_changed = $false
    caddy_routes_changed = $false
    tls_cipher_order_changed = $false
}
Write-RC10Json -Path (Join-Path $Dest "deployment.json") -Object $deployment

Write-Host "PASS RC1-10 files installed with restricted ACL" -ForegroundColor Green
Write-Host "RC1_10_INSTALLED=True" -ForegroundColor Green
Write-Host "NEXT=Run Apply-RC1-10-SafeHardening.ps1, then Set-RC1-10-ReleaseAttestation.ps1" -ForegroundColor Yellow
