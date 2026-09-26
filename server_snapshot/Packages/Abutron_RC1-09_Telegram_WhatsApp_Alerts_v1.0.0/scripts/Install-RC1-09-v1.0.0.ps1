$ErrorActionPreference="Stop"
Write-Host "=== ABUTRON RC1-09 TELEGRAM + WHATSAPP ALERTS v1.0.0 ===" -ForegroundColor Yellow
$Pkg=(Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$Base="C:\Abutron\Jarvis"
$Live=Join-Path $Base "rc1_09"
$LivePkg=Join-Path $Live "rc1_09"
$Py="C:\Abutron\Jarvis\.venv\Scripts\python.exe"
if(-not(Test-Path $Py)){ $Py=(Get-Command python.exe -ErrorAction Stop).Source }

# Certified prerequisite: RC1-08 must be healthy and fail-closed.
$h=Invoke-RestMethod "http://127.0.0.1:8788/health" -TimeoutSec 15
if($h.status -ne "ok" -or $h.mode -ne "OBSERVE_ONLY"){ throw "RC1-08 prerequisite failed" }
Write-Host "PASS RC1-08 healthy / OBSERVE_ONLY" -ForegroundColor Green

# Deterministic tests before live modification.
Push-Location $Pkg
$env:PYTHONPATH=(Join-Path $Pkg "src")
& $Py -m unittest discover -s tests -v
if($LASTEXITCODE -ne 0){ throw "RC1-09 deterministic tests failed; live service not modified" }
& $Py -m compileall -q (Join-Path $Pkg "src")
if($LASTEXITCODE -ne 0){ throw "RC1-09 compile failed; live service not modified" }
Pop-Location
Write-Host "PASS deterministic tests + Python compile" -ForegroundColor Green

$stamp=Get-Date -Format "yyyyMMdd-HHmmss"
$backup="C:\Abutron\Jarvis\backups\rc1_09_$stamp"
if(Test-Path $Live){ Copy-Item $Live $backup -Recurse -Force }

New-Item -ItemType Directory -Force -Path $Live,$LivePkg,"C:\Abutron\Jarvis\data","C:\Abutron\Jarvis\logs" | Out-Null
Copy-Item (Join-Path $Pkg "src\rc1_09\*") $LivePkg -Recurse -Force
Copy-Item (Join-Path $Pkg "scripts\run-rc1-09.ps1") (Join-Path $Live "run-rc1-09.ps1") -Force

$envPath=Join-Path $Live ".env"
if(-not(Test-Path $envPath)){
    Copy-Item (Join-Path $Pkg ".env.example") $envPath
}
# Restrict secret file to Administrators + SYSTEM.
& icacls $envPath /inheritance:r /grant:r "Administrators:F" "SYSTEM:F" | Out-Null

$task="Abutron-Jarvis-RC1-09"
if(Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue){
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false
}
$action=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$Live\run-rc1-09.ps1`""
$trigger=New-ScheduledTaskTrigger -AtStartup
$settings=New-ScheduledTaskSettingsSet -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 3650)
$principal=New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $task

$deadline=(Get-Date).AddSeconds(60)
do{
    try{
        $rh=Invoke-RestMethod "http://127.0.0.1:8789/health" -TimeoutSec 5
        if($rh.mode -eq "NOTIFY_ONLY" -and $rh.actions_enabled -eq $false){ break }
    }catch{}
    Start-Sleep 2
}while((Get-Date)-lt $deadline)
if(-not $rh -or $rh.mode -ne "NOTIFY_ONLY"){ throw "RC1-09 did not start" }

Write-Host "PASS RC1-09 service Running / NOTIFY_ONLY" -ForegroundColor Green
Write-Host "Backup=$backup"
Write-Host "RC1_09_INSTALLED=True" -ForegroundColor Green
Write-Host "NEXT=Configure Telegram, then WhatsApp/Meta, then certification" -ForegroundColor Yellow
