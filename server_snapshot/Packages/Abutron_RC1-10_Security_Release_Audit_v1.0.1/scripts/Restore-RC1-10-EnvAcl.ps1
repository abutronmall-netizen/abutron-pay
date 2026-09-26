param([string]$BackupFile="")
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")
Assert-RC10Administrator

if(-not $BackupFile) {
    $f = Get-RC10LatestFile -Directory $script:RC10Backups -Filter "env_acl_before_*.json"
    if(-not $f) { throw "No RC1-10 environment ACL backup found." }
    $BackupFile = $f.FullName
}
$data = Get-Content $BackupFile -Raw | ConvertFrom-Json
foreach($e in @($data.entries)) {
    if(Test-Path $e.path) {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetSecurityDescriptorSddlForm([string]$e.sddl)
        Set-Acl -Path $e.path -AclObject $acl
        Write-Host "RESTORED ACL: $($e.path)"
    }
}
Write-Host "RC1_10_ENV_ACL_ROLLBACK=PASS" -ForegroundColor Green
