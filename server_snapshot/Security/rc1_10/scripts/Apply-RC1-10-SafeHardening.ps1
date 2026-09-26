$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")

Assert-RC10Administrator
Assert-RC10ReleaseSafety | Out-Null
$policy = Get-RC10Policy
$stamp = Get-RC10Timestamp
$aclBackupPath = Join-Path $script:RC10Backups "env_acl_before_$stamp.json"
$aclBackup = @()
$changed = @()

$paths = @($policy.secret_env_candidates)
foreach($base in @("C:\Abutron\TradingPlatformV4","C:\Abutron\Jarvis")) {
    if(Test-Path $base) {
        $paths += Get-ChildItem $base -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like ".env*" -and
                $_.FullName -notmatch "\\backups\\" -and
                $_.FullName -notmatch "\\Packages\\" -and
                $_.FullName -notmatch "\\node_modules\\" -and
                $_.FullName -notmatch "\\\.venv\\" -and
                $_.FullName -notmatch "\\Security\\rc1_10\\"
            } | Select-Object -ExpandProperty FullName
    }
}
$paths = @($paths | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique)

# Capture and persist every original ACL BEFORE applying a single change.
foreach($path in $paths) {
    $old = Get-Acl $path
    $aclBackup += [pscustomobject]@{ path=$path; sddl=$old.Sddl }
}
Write-RC10Json -Path $aclBackupPath -Object ([ordered]@{
    version="1.0.1"
    created_utc=(Get-Date).ToUniversalTime().ToString("o")
    entries=$aclBackup
})
Write-Host "ACL_BACKUP_CREATED=$aclBackupPath"

try {
    foreach($path in $paths) {
        $acl = Get-Acl $path
        $acl.SetAccessRuleProtection($true,$true)

        foreach($rule in @($acl.Access)) {
            # Regex contains a literal Windows backslash, which must be escaped for the regex engine.
            if($rule.IdentityReference.Value -match '(?i)^(Everyone|BUILTIN\\Users|Authenticated Users)$') {
                [void]$acl.RemoveAccessRuleSpecific($rule)
            }
        }

        $adminRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            "BUILTIN\Administrators",
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $systemRule = [System.Security.AccessControl.FileSystemAccessRule]::new(
            "NT AUTHORITY\SYSTEM",
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl.SetAccessRule($adminRule)
        $acl.SetAccessRule($systemRule)
        Set-Acl -Path $path -AclObject $acl
        $changed += $path
    }
}
catch {
    Write-Host "ACL_HARDENING_FAILURE=$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Starting automatic ACL rollback..." -ForegroundColor Yellow
    $data = Get-Content $aclBackupPath -Raw | ConvertFrom-Json
    foreach($e in @($data.entries)) {
        if(Test-Path $e.path) {
            try {
                $restore = New-Object System.Security.AccessControl.FileSecurity
                $restore.SetSecurityDescriptorSddlForm([string]$e.sddl)
                Set-Acl -Path $e.path -AclObject $restore
            } catch {
                Write-Host "ROLLBACK_WARNING=$($e.path): $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
    throw
}

Assert-RC10ReleaseSafety | Out-Null

Write-Host "PASS secret-file ACL hardening applied to $($changed.Count) live .env file(s)" -ForegroundColor Green
Write-Host "ACL_BACKUP=$aclBackupPath"
Write-Host "NO_RDP_CHANGE=True"
Write-Host "NO_FIREWALL_RULE_CHANGE=True"
Write-Host "NO_CADDY_ROUTE_CHANGE=True"
Write-Host "NO_TRADING_CHANGE=True"
