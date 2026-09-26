param(
  [string]$Root='C:\Abutron\TradingPlatformV4',
  [string]$BackupRoot='C:\Abutron\Backups\Step22',
  [string]$Caddyfile='C:\caddy\Caddyfile'
)
$ErrorActionPreference='Stop'
$Py=Join-Path $Root '.venv_ctrader\Scripts\python.exe'; if(!(Test-Path $Py)){throw 'CTRADER_PYTHON_MISSING'}
$Ops=Join-Path $Root 'ctrader_cloud_gateway\ops'; $Stamp=Get-Date -Format 'yyyyMMdd_HHmmss'; $Out=Join-Path $BackupRoot $Stamp
& $Py (Join-Path $Ops 'backup_sqlite.py') --root $Root --output $Out --caddyfile $Caddyfile
if($LASTEXITCODE -ne 0){throw 'STEP22_BACKUP_CREATE_FAIL'}
& $Py (Join-Path $Ops 'verify_backup.py') --manifest (Join-Path $Out 'backup_manifest.json')
if($LASTEXITCODE -ne 0){throw 'STEP22_BACKUP_VERIFY_FAIL'}
# Backups contain encrypted-token DBs and environment files; restrict access to SYSTEM and local Administrators.
& icacls.exe $Out /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C | Out-Null
if($LASTEXITCODE -ne 0){throw 'STEP22_BACKUP_ACL_FAIL'}
Write-Host 'STEP22_BACKUP_ACL=PASS'
Write-Host 'STEP22_BACKUP_DRILL=PASS'
Write-Host "STEP22_BACKUP_PATH=$Out"
