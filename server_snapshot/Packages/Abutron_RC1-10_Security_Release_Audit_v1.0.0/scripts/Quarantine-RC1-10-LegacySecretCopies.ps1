$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")
Assert-RC10Administrator
Assert-RC10ReleaseSafety | Out-Null

$stamp=Get-RC10Timestamp
$dest=Join-Path $script:RC10Backups ("legacy_secret_quarantine_"+$stamp)
New-Item -ItemType Directory -Force -Path $dest | Out-Null
& icacls $dest /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null
if($LASTEXITCODE -ne 0){throw "Could not secure legacy secret quarantine directory."}

$candidates=@()
foreach($base in @("C:\Abutron\TradingPlatformV4","C:\Abutron\Jarvis")){
    if(Test-Path $base){
        $candidates += Get-ChildItem $base -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '(?i)^\.env\.(before|bak|backup|old|copy)' -and
                $_.FullName -notmatch '\\Security\\rc1_10\\' -and
                $_.FullName -notmatch '\\backups\\' -and
                $_.FullName -notmatch '\\Packages\\' -and
                $_.FullName -notmatch '\\node_modules\\' -and
                $_.FullName -notmatch '\\\.venv\\'
            }
    }
}
$candidates=@($candidates | Sort-Object FullName -Unique)
$items=@(); $failures=@()
foreach($f in $candidates){
    try{
        $bytes=[IO.File]::ReadAllBytes($f.FullName)
        $hash=Get-RC10HashBytes $bytes
        $enc=Protect-RC10Bytes $bytes
        $safe=((Get-RC10HashString $f.FullName).Substring(0,12)+"_"+$f.Name+".dpapi")
        $out=Join-Path $dest $safe
        [IO.File]::WriteAllBytes($out,$enc)
        $dec=Unprotect-RC10Bytes ([IO.File]::ReadAllBytes($out))
        if((Get-RC10HashBytes $dec) -ne $hash){throw "DPAPI verification mismatch."}
        Remove-Item $f.FullName -Force
        $items += [pscustomobject]@{source=$f.FullName;encrypted_backup=$out;sha256=$hash;removed_plaintext=$true}
    }catch{
        $failures += [pscustomobject]@{source=$f.FullName;error=$_.Exception.Message}
    }
}
$report=[ordered]@{
    version="1.0.0"
    generated_utc=(Get-Date).ToUniversalTime().ToString("o")
    candidate_count=$candidates.Count
    quarantined_count=$items.Count
    failure_count=$failures.Count
    result=if($failures.Count -eq 0){"PASS"}else{"FAIL"}
    items=$items
    failures=$failures
}
$path=Join-Path $script:RC10Reports ("legacy_secret_quarantine_"+$stamp+".json")
Write-RC10Json -Path $path -Object $report
Write-Host "RC1_10_LEGACY_SECRET_QUARANTINE=$($report.result)"
Write-Host "QUARANTINED=$($items.Count) FAILURES=$($failures.Count)"
Write-Host "REPORT=$path"
if($report.result -ne "PASS"){throw "Legacy secret quarantine failed."}
