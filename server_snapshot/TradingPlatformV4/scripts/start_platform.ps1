$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
Set-Location $Root
$Python="$Root\.venv\Scripts\python.exe"
if (!(Test-Path $Python)) { throw "Run scripts\install_windows.ps1 first." }
New-Item -ItemType Directory -Force -Path "$Root\logs" | Out-Null
$procs=@()
$procs += Start-Process -FilePath $Python -ArgumentList '-m','uvicorn','mt5_bridge.app:app','--host','127.0.0.1','--port','8090' -WorkingDirectory $Root -PassThru -RedirectStandardOutput "$Root\logs\mt5.out.log" -RedirectStandardError "$Root\logs\mt5.err.log"
Start-Sleep -Seconds 2
$procs += Start-Process -FilePath $Python -ArgumentList '-m','uvicorn','abutron.api:app','--host','127.0.0.1','--port','8088' -WorkingDirectory $Root -PassThru -RedirectStandardOutput "$Root\logs\api.out.log" -RedirectStandardError "$Root\logs\api.err.log"
Start-Sleep -Seconds 2
$procs += Start-Process -FilePath $Python -ArgumentList '-m','abutron.worker' -WorkingDirectory $Root -PassThru -RedirectStandardOutput "$Root\logs\worker.out.log" -RedirectStandardError "$Root\logs\worker.err.log"
$procs | Select-Object Id,ProcessName | Format-Table
$procs.Id | Set-Content "$Root\data\platform_pids.txt"
Write-Host "Abutron v4 started. Admin: http://127.0.0.1:8088/admin" -ForegroundColor Green
