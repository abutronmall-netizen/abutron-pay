Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RC10Root = "C:\Abutron\Security\rc1_10"
$script:RC10Reports = Join-Path $script:RC10Root "reports"
$script:RC10Backups = Join-Path $script:RC10Root "backups"
$script:RC10Integrity = Join-Path $script:RC10Root "integrity"
$script:RC10Certification = Join-Path $script:RC10Root "certification"
$script:RC10PolicyPath = Join-Path $script:RC10Root "config\rc1_10_policy.json"

function Assert-RC10Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    if(-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "RC1-10 requires an elevated Administrator PowerShell."
    }
}

function Get-RC10Policy {
    if(-not(Test-Path $script:RC10PolicyPath)) {
        throw "RC1-10 policy not found: $script:RC10PolicyPath"
    }
    return (Get-Content $script:RC10PolicyPath -Raw | ConvertFrom-Json)
}

function Get-RC10Timestamp {
    return (Get-Date -Format "yyyyMMdd-HHmmss")
}

function Write-RC10Json {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Object
    )
    $parent = Split-Path $Path -Parent
    if($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $Object | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
}

function New-RC10Finding {
    param(
        [Parameter(Mandatory=$true)][string]$Control,
        [Parameter(Mandatory=$true)][ValidateSet("PASS","WARN","FAIL","INFO")][string]$Status,
        [Parameter(Mandatory=$true)][string]$Message,
        $Evidence = $null
    )
    [pscustomobject]@{
        control = $Control
        status = $Status
        message = $Message
        evidence = $Evidence
    }
}

function Get-RC10CoreHealth {
    Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 15
}
function Get-RC108Health {
    Invoke-RestMethod "http://127.0.0.1:8788/health" -TimeoutSec 15
}
function Get-RC109Health {
    Invoke-RestMethod "http://127.0.0.1:8789/health" -TimeoutSec 15
}

function Assert-RC10ReleaseSafety {
    $core = Get-RC10CoreHealth
    if($core.status -ne "ok") { throw "Core health is not ok." }
    if($core.execution_enabled -ne $false) { throw "SECURITY BLOCK: core execution_enabled is not false." }
    if($core.mt5.live_trading -ne $false) { throw "SECURITY BLOCK: MT5 live_trading is not false." }
    if($core.mt5.management_enabled -ne $false) { throw "SECURITY BLOCK: MT5 management_enabled is not false." }

    $r8 = Get-RC108Health
    if($r8.status -ne "ok" -or $r8.mode -ne "OBSERVE_ONLY") {
        throw "SECURITY BLOCK: RC1-08 is not healthy OBSERVE_ONLY."
    }

    $r9 = Get-RC109Health
    if($r9.status -ne "ok" -or $r9.mode -ne "NOTIFY_ONLY" -or $r9.actions_enabled -ne $false) {
        throw "SECURITY BLOCK: RC1-09 is not healthy NOTIFY_ONLY."
    }
    if($r9.channels.telegram -ne $true) {
        throw "SECURITY BLOCK: certified Telegram channel is not enabled."
    }

    [pscustomobject]@{
        core = $core
        rc1_08 = $r8
        rc1_09 = $r9
    }
}

function Test-RC10LoopbackAddress {
    param([string]$Address)
    if($Address -eq "127.0.0.1" -or $Address -eq "::1") { return $true }
    if($Address -match "^127\.") { return $true }
    return $false
}

function Get-RC10LatestFile {
    param(
        [Parameter(Mandatory=$true)][string]$Directory,
        [Parameter(Mandatory=$true)][string]$Filter
    )
    if(-not(Test-Path $Directory)) { return $null }
    Get-ChildItem $Directory -Filter $Filter -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Get-RC10EnvMap {
    param([Parameter(Mandatory=$true)][string]$Path)
    $map = @{}
    if(-not(Test-Path $Path)) { return $map }
    foreach($raw in Get-Content $Path) {
        $line = $raw.Trim()
        if(-not $line -or $line.StartsWith("#") -or -not $line.Contains("=")) { continue }
        $idx = $line.IndexOf("=")
        $k = $line.Substring(0,$idx).Trim()
        $v = $line.Substring($idx+1).Trim().Trim('"').Trim("'")
        if($k) { $map[$k] = $v }
    }
    return $map
}

function Get-RC10HashString {
    param([Parameter(Mandatory=$true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $sha.Dispose() }
}

function Get-RC10HashBytes {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return (($hash | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $sha.Dispose() }
}

function Get-RC10ActiveRdpText {
    try { return ((quser 2>$null | Out-String) + "`n" + (qwinsta 2>$null | Out-String)) }
    catch { return "" }
}

function Protect-RC10Bytes {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    return [System.Security.Cryptography.ProtectedData]::Protect(
        $Bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )
}

function Unprotect-RC10Bytes {
    param([Parameter(Mandatory=$true)][byte[]]$Bytes)
    return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $Bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )
}
