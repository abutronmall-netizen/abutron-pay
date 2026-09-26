param([string]$Root="C:\Abutron\TradingPlatformV4")
$ErrorActionPreference="Stop"

$api=Join-Path $Root "abutron\api.py"
$backup=Get-ChildItem (Join-Path $Root "abutron") -Filter "api.py.pre_step26a_*" -File |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(-not $backup){throw "STEP26A_API_BACKUP_NOT_FOUND"}
Copy-Item $backup.FullName $api -Force

foreach($p in @(
    (Join-Path $Root "abutron\step26a_api.py"),
    (Join-Path $Root "abutron\step26a_models.py"),
    (Join-Path $Root "admin\step26a.html")
)){
    if(Test-Path $p){Remove-Item $p -Force}
}
$mobile=Join-Path $Root "mobile\AbutronMobile"
if(Test-Path $mobile){Remove-Item $mobile -Recurse -Force}

Write-Host "STEP26A_ROLLBACK=PASS"
Write-Host "Step26A database tables were intentionally retained to avoid destructive data loss."
Write-Host "Restart the platform after rollback."
