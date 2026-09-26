param([switch]$FailOnBlocker)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")

Assert-RC10Administrator
$manifestPath = Join-Path $script:RC10Integrity "manifest.json"
$keyPath = Join-Path $script:RC10Integrity "hmac_key.dpapi"
$sigPath = Join-Path $script:RC10Integrity "manifest.hmac"
foreach($p in @($manifestPath,$keyPath,$sigPath)) { if(-not(Test-Path $p)){throw "Integrity artifact missing: $p"} }

$key = Unprotect-RC10Bytes ([IO.File]::ReadAllBytes($keyPath))
$h = [System.Security.Cryptography.HMACSHA256]::new($key)
try {
    $raw = Get-Content $manifestPath -Raw
    $calcBytes = $h.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw))
    $calc = (($calcBytes | ForEach-Object { $_.ToString("x2") }) -join "")
} finally { $h.Dispose() }
$stored = (Get-Content $sigPath -Raw).Trim().ToLowerInvariant()
if($calc -ne $stored) { throw "RC1-10 integrity manifest HMAC verification failed." }

$manifest = $raw | ConvertFrom-Json
$changes = @()
foreach($e in @($manifest.entries)) {
    if($e.type -eq "FILE") {
        if(-not(Test-Path $e.name)) {
            $changes += [pscustomobject]@{type="MISSING_FILE";name=$e.name}
        } else {
            $now = (Get-FileHash $e.name -Algorithm SHA256).Hash.ToLowerInvariant()
            if($now -ne [string]$e.sha256) {
                $changes += [pscustomobject]@{type="FILE_CHANGED";name=$e.name}
            }
        }
    } elseif($e.type -eq "TASK") {
        $task = Get-ScheduledTask -TaskName $e.name -ErrorAction SilentlyContinue
        if(-not $task) {
            $changes += [pscustomobject]@{type="MISSING_TASK";name=$e.name}
        } else {
            $now = Get-RC10HashString (Export-ScheduledTask -TaskName $e.name)
            if($now -ne [string]$e.sha256) {
                $changes += [pscustomobject]@{type="TASK_CHANGED";name=$e.name}
            }
        }
    }
}
$report = [ordered]@{
    version="1.0.0"
    generated_utc=(Get-Date).ToUniversalTime().ToString("o")
    manifest_hmac="PASS"
    change_count=$changes.Count
    result=if($changes.Count -eq 0){"PASS"}else{"FAIL"}
    changes=$changes
}
$path = Join-Path $script:RC10Reports ("integrity_"+(Get-RC10Timestamp)+".json")
Write-RC10Json -Path $path -Object $report
Write-Host "RC1_10_INTEGRITY_RESULT=$($report.result)"
Write-Host "CHANGE_COUNT=$($changes.Count)"
Write-Host "REPORT=$path"
if($FailOnBlocker -and $changes.Count -gt 0) { throw "RC1-10 integrity drift detected." }
