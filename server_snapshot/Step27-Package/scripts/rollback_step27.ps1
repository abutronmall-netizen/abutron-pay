param(
    [string]$Root="C:\Abutron\TradingPlatformV4",
    [string]$BackupDir
)
$ErrorActionPreference="Stop"
if(-not $BackupDir){throw "Usage: .\rollback_step27.ps1 -BackupDir C:\Abutron\Backups\PreStep27\<timestamp>"}
if(-not(Test-Path $BackupDir)){throw "BACKUP_NOT_FOUND=$BackupDir"}

$apiBackup=Join-Path $BackupDir "api.py"
if(-not(Test-Path $apiBackup)){throw "API_BACKUP_MISSING=$apiBackup"}
Copy-Item $apiBackup (Join-Path $Root "abutron\api.py") -Force

foreach($f in @("step27_models.py","step27_service.py","step27_api.py")){
    $backup=Join-Path $BackupDir $f
    $dest=Join-Path $Root ("abutron\"+$f)
    if(Test-Path $backup){Copy-Item $backup $dest -Force}
    elseif(Test-Path $dest){Remove-Item $dest -Force}
}
$adminBackup=Join-Path $BackupDir "step27.html"
$adminDest=Join-Path $Root "admin\step27.html"
if(Test-Path $adminBackup){Copy-Item $adminBackup $adminDest -Force}
elseif(Test-Path $adminDest){Remove-Item $adminDest -Force}

Write-Host "STEP27_ROLLBACK_SOURCE=PASS"
Write-Host "Restart/activate the API after rollback. Database tables are intentionally retained for audit/history."
