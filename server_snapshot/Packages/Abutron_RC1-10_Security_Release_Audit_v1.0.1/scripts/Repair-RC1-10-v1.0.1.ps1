$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

Write-Host "=== ABUTRON RC1-10 v1.0.1 REPAIR ===" -ForegroundColor Yellow

$id=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($id)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    throw "Run this repair from Administrator PowerShell."
}

$PackageRoot=(Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Live="C:\Abutron\Security\rc1_10"
if(-not(Test-Path $Live)){throw "RC1-10 v1.0.0 live installation not found at $Live"}

$stamp=Get-Date -Format "yyyyMMdd-HHmmss"
$backup=Join-Path $Live ("backups\repair_v1_0_1_"+$stamp)
New-Item -ItemType Directory -Force -Path $backup | Out-Null

Copy-Item (Join-Path $Live "lib") (Join-Path $backup "lib") -Recurse -Force
Copy-Item (Join-Path $Live "scripts") (Join-Path $backup "scripts") -Recurse -Force

Copy-Item (Join-Path $PackageRoot "lib\RC1-10.Common.ps1") (Join-Path $Live "lib\RC1-10.Common.ps1") -Force
Copy-Item (Join-Path $PackageRoot "scripts\Apply-RC1-10-SafeHardening.ps1") (Join-Path $Live "scripts\Apply-RC1-10-SafeHardening.ps1") -Force
Copy-Item (Join-Path $PackageRoot "scripts\Quarantine-RC1-10-LegacySecretCopies.ps1") (Join-Path $Live "scripts\Quarantine-RC1-10-LegacySecretCopies.ps1") -Force

# Windows PowerShell parser gate on every live RC1-10 script.
$parseFailures=@()
foreach($f in Get-ChildItem (Join-Path $Live "scripts") -Filter "*.ps1" -File){
    $tokens=$null
    $errors=$null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $f.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if($errors.Count -gt 0){
        foreach($e in $errors){
            $parseFailures += [pscustomobject]@{file=$f.FullName;message=$e.Message}
        }
    }
}
$tokens=$null
$errors=$null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $Live "lib\RC1-10.Common.ps1"),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if($errors.Count -gt 0){
    foreach($e in $errors){
        $parseFailures += [pscustomobject]@{file=(Join-Path $Live "lib\RC1-10.Common.ps1");message=$e.Message}
    }
}
if($parseFailures.Count -gt 0){
    $parseFailures | Format-Table -AutoSize
    throw "v1.0.1 PowerShell parser gate failed. Live hardening was not run."
}
Write-Host "PASS Windows PowerShell parser gate" -ForegroundColor Green

. (Join-Path $Live "lib\RC1-10.Common.ps1")
Assert-RC10Administrator
Assert-RC10ReleaseSafety | Out-Null
Assert-RC10DpapiAvailable | Out-Null
Write-Host "PASS release safety and DPAPI compatibility" -ForegroundColor Green

# Prove the corrected ACL regex compiles before touching ACLs.
$null = [regex]::new('(?i)^(Everyone|BUILTIN\\Users|Authenticated Users)$')
Write-Host "PASS corrected ACL identity regex" -ForegroundColor Green

& (Join-Path $Live "scripts\Apply-RC1-10-SafeHardening.ps1")
& (Join-Path $Live "scripts\Quarantine-RC1-10-LegacySecretCopies.ps1")

Write-Host "RC1_10_REPAIR_V1_0_1=PASS" -ForegroundColor Green
Write-Host "BACKUP=$backup"
Write-Host "NEXT=Rotate the exposed cTrader/Spotware client secret, then run Set-RC1-10-ReleaseAttestation.ps1" -ForegroundColor Yellow
