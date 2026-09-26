param([switch]$FailOnBlocker)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")

Assert-RC10Administrator
Assert-RC10ReleaseSafety | Out-Null
$policy = Get-RC10Policy
$stamp = Get-RC10Timestamp
$backupRoot = Join-Path $script:RC10Backups $stamp
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
& icacls $backupRoot /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null
if($LASTEXITCODE -ne 0) { throw "Could not secure backup directory." }

$items = @()
$failures = @()

function Save-ProtectedFile([string]$src,[string]$label) {
    if(-not(Test-Path $src)) { return }
    try {
        $bytes = [IO.File]::ReadAllBytes($src)
        $srcHash = Get-RC10HashBytes $bytes
        $enc = Protect-RC10Bytes $bytes
        $safe = ($label -replace '[^A-Za-z0-9_.-]','_') + ".dpapi"
        $dst = Join-Path $backupRoot $safe
        [IO.File]::WriteAllBytes($dst,$enc)
        $dec = Unprotect-RC10Bytes ([IO.File]::ReadAllBytes($dst))
        $restoreHash = Get-RC10HashBytes $dec
        if($srcHash -ne $restoreHash) { throw "Hash mismatch after DPAPI restore test." }
        $script:items += [pscustomobject]@{source=$src;backup=$dst;type="DPAPI_FILE";sha256=$srcHash;restore_test="PASS"}
    } catch {
        $script:failures += [pscustomobject]@{source=$src;error=$_.Exception.Message}
    }
}

# Encrypt live secret files and critical configuration at rest in the RC1-10 rollback set.
$critical = @(
    "C:\caddy\Caddyfile",
    "C:\Abutron\TradingPlatformV4\.env",
    "C:\Abutron\Jarvis\.env",
    "C:\Abutron\Jarvis\rc1_09\.env"
)
foreach($f in $critical) { Save-ProtectedFile $f ([IO.Path]::GetFileName($f)+"_"+(Get-RC10HashString $f).Substring(0,10)) }

# Use sqlite3 online backup via the platform Python, validate quick_check, encrypt snapshot, then remove plaintext.
$python = "C:\Abutron\TradingPlatformV4\.venv\Scripts\python.exe"
if(-not(Test-Path $python)) { $python = (Get-Command python.exe -ErrorAction Stop).Source }
$dbPaths = @()
foreach($r in @($policy.sqlite_roots)) {
    if(Test-Path $r) {
        $dbPaths += Get-ChildItem $r -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @(".db",".sqlite",".sqlite3") } |
            Select-Object -ExpandProperty FullName
    }
}
$dbPaths = $dbPaths | Sort-Object -Unique

$pyScript = Join-Path $backupRoot "sqlite_backup_test.py"
@'
import json, sqlite3, sys, pathlib
src_path=sys.argv[1]
dst_path=sys.argv[2]
src=sqlite3.connect(f"file:{pathlib.Path(src_path).as_posix()}?mode=ro", uri=True, timeout=30)
dst=sqlite3.connect(dst_path, timeout=30)
src.backup(dst)
src.close()
res=dst.execute("PRAGMA quick_check").fetchone()[0]
dst.close()
print(res)
sys.exit(0 if res=="ok" else 3)
'@ | Set-Content $pyScript -Encoding UTF8

foreach($db in $dbPaths) {
    try {
        $plain = Join-Path $backupRoot ("db_"+(Get-RC10HashString $db).Substring(0,12)+".sqlite")
        $out = & $python $pyScript $db $plain
        if($LASTEXITCODE -ne 0 -or ($out | Out-String).Trim() -ne "ok") { throw "SQLite quick_check/backup failed." }
        $plainBytes = [IO.File]::ReadAllBytes($plain)
        $plainHash = Get-RC10HashBytes $plainBytes
        $enc = Protect-RC10Bytes $plainBytes
        $dst = $plain + ".dpapi"
        [IO.File]::WriteAllBytes($dst,$enc)
        Remove-Item $plain -Force
        $restored = Unprotect-RC10Bytes ([IO.File]::ReadAllBytes($dst))
        if((Get-RC10HashBytes $restored) -ne $plainHash) { throw "Encrypted SQLite restore hash mismatch." }
        $tmpRestore = $plain + ".restore-test"
        [IO.File]::WriteAllBytes($tmpRestore,$restored)
        $out2 = & $python $pyScript $tmpRestore ($tmpRestore+".copy")
        if(Test-Path ($tmpRestore+".copy")) { Remove-Item ($tmpRestore+".copy") -Force }
        Remove-Item $tmpRestore -Force
        if($LASTEXITCODE -ne 0 -or ($out2 | Out-String).Trim() -ne "ok") { throw "Restored SQLite quick_check failed." }
        $items += [pscustomobject]@{source=$db;backup=$dst;type="DPAPI_SQLITE";sha256=$plainHash;restore_test="PASS"}
    } catch {
        $failures += [pscustomobject]@{source=$db;error=$_.Exception.Message}
    }
}
Remove-Item $pyScript -Force -ErrorAction SilentlyContinue

$report = [ordered]@{
    version="1.0.0"
    generated_utc=(Get-Date).ToUniversalTime().ToString("o")
    backup_root=$backupRoot
    item_count=$items.Count
    failure_count=$failures.Count
    local_machine_dpapi=$true
    note="Local rollback set is DPAPI-protected to this Windows server. Provider/off-host snapshot is separately required by release attestation."
    result=if($failures.Count -eq 0 -and $items.Count -gt 0){"PASS"}else{"FAIL"}
    items=$items
    failures=$failures
}
$path = Join-Path $script:RC10Reports ("backup_restore_"+$stamp+".json")
Write-RC10Json -Path $path -Object $report
Write-Host "RC1_10_BACKUP_RESTORE_RESULT=$($report.result)"
Write-Host "ITEMS=$($items.Count) FAILURES=$($failures.Count)"
Write-Host "BACKUP_ROOT=$backupRoot"
Write-Host "REPORT=$path"
if($FailOnBlocker -and $report.result -ne "PASS") { throw "RC1-10 backup/restore test failed." }
