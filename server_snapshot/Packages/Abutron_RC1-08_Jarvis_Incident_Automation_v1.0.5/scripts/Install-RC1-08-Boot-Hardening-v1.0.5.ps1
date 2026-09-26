param(
  [string]$JarvisRoot = "C:\Abutron\Jarvis",
  [string]$PackageRoot = "C:\Abutron\Packages\Abutron_RC1-08_Jarvis_Incident_Automation_v1.0.5"
)
$ErrorActionPreference='Stop'
$ts=Get-Date -Format 'yyyyMMdd-HHmmss'
$rc=Join-Path $JarvisRoot 'rc1_08'
$livePkg=Join-Path $rc 'rc1_08'
$cfgPath=Join-Path $rc 'config.json'
$backup=Join-Path $JarvisRoot "backups\rc1_08_boot_hardening_$ts"
$python=Join-Path $JarvisRoot '.venv\Scripts\python.exe'

function Wait-Json([string]$Url,[int]$Seconds=60){
  $deadline=(Get-Date).AddSeconds($Seconds); $last=$null
  do { try { return Invoke-RestMethod -Uri $Url -TimeoutSec 5 } catch { $last=$_.Exception.Message; Start-Sleep 2 } } while((Get-Date)-lt $deadline)
  throw "Health timeout: $Url ; last_error=$last"
}

Write-Host '=== RC1-08 v1.0.5 BOOT / TRANSIENT HARDENING ===' -ForegroundColor Yellow
if(!(Test-Path $cfgPath)){throw "Missing $cfgPath"}
if(!(Test-Path $livePkg)){throw "Missing $livePkg"}
if(!(Test-Path $python)){throw "Missing Jarvis Python $python"}
New-Item -ItemType Directory -Force $backup | Out-Null
Copy-Item $cfgPath (Join-Path $backup 'config.json.before') -Force
Copy-Item $livePkg (Join-Path $backup 'rc1_08.before') -Recurse -Force

# Offline deterministic tests BEFORE modifying the live service.
Push-Location $PackageRoot
try {
  & $python -m unittest discover -s tests -v
  if($LASTEXITCODE -ne 0){throw 'v1.0.5 deterministic tests failed; live service was not modified'}
  & $python -m py_compile (Join-Path $PackageRoot 'src\rc1_08\config.py') (Join-Path $PackageRoot 'src\rc1_08\engine.py') (Join-Path $PackageRoot 'src\rc1_08\service.py')
  if($LASTEXITCODE -ne 0){throw 'v1.0.5 Python compilation failed; live service was not modified'}
} finally { Pop-Location }
Write-Host 'PASS 10 deterministic tests + Python compile' -ForegroundColor Green

# Copy only after tests pass.
Copy-Item (Join-Path $PackageRoot 'src\rc1_08\*') $livePkg -Recurse -Force

$cfg=Get-Content $cfgPath -Raw | ConvertFrom-Json
$cfg | Add-Member -NotePropertyName startup_grace_seconds -NotePropertyValue 90 -Force
$cfg | Add-Member -NotePropertyName failure_confirmations -NotePropertyValue 2 -Force
foreach($check in @($cfg.checks)){
  if($check.name -in @('jarvis_api','kronos_health','mt5_bridge_health','mt5_terminal')){
    $check | Add-Member -NotePropertyName failure_confirmations -NotePropertyValue 2 -Force
  }
}
$cfg | ConvertTo-Json -Depth 30 | Set-Content $cfgPath -Encoding UTF8

Stop-ScheduledTask -TaskName 'Abutron-Jarvis-RC1-08' -ErrorAction SilentlyContinue
Start-Sleep 2
Start-ScheduledTask -TaskName 'Abutron-Jarvis-RC1-08'
$h=Wait-Json 'http://127.0.0.1:8788/health' 60
if($h.status -ne 'ok' -or $h.mode -ne 'OBSERVE_ONLY'){throw 'RC1-08 did not restart safely'}
if(-not $h.startup_grace_active){throw 'Expected startup grace to be active immediately after restart'}
Write-Host "PASS RC1-08 restarted OBSERVE_ONLY; grace_remaining=$($h.startup_grace_remaining_seconds)s" -ForegroundColor Green

$m=(Invoke-WebRequest 'http://127.0.0.1:8788/metrics' -UseBasicParsing -TimeoutSec 10).Content
if($m -notmatch 'jarvis_rc1_08_suppressed_failures_total' -or $m -notmatch 'jarvis_rc1_08_startup_grace_active 1'){
  throw 'New boot-hardening metrics are missing'
}
Write-Host 'PASS boot-hardening metrics exposed' -ForegroundColor Green
Write-Host "Backup=$backup"
Write-Host 'BOOT_HARDENING_INSTALLED=True' -ForegroundColor Green
Write-Host 'NEXT=Reboot once, then run scripts\Certify-RC1-08-PostReboot-v1.0.5.ps1' -ForegroundColor Yellow
