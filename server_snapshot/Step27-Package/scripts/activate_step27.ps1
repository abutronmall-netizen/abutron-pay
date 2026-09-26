param([string]$Root="C:\Abutron\TradingPlatformV4")
$ErrorActionPreference="Stop"
$Python=Join-Path $Root ".venv\Scripts\python.exe"
if(-not(Test-Path $Python)){throw "PYTHON_NOT_FOUND=$Python"}

$health=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
if($health.execution_enabled -ne $false){throw "STEP27_ACTIVATE_ABORT_EXECUTION_ON"}
if($health.mt5.live_trading -ne $false){throw "STEP27_ACTIVATE_ABORT_MT5_LIVE_ON"}
if($health.mt5.management_enabled -ne $false){throw "STEP27_ACTIVATE_ABORT_MANAGEMENT_ON"}

$conn=Get-NetTCPConnection -LocalPort 8088 -State Listen -ErrorAction Stop | Select-Object -First 1
$listenerPid=[int]$conn.OwningProcess
$listener=Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $listenerPid)
$cmd=[string]$listener.CommandLine
if($cmd -notmatch '(?i)-m\s+uvicorn' -or $cmd -notmatch '(?i)abutron\.api:app' -or $cmd -notmatch '(?i)--port\s+8088'){
    throw ("STEP27_ACTIVATE_ABORT_UNKNOWN_8088_OWNER PID={0}" -f $listenerPid)
}

$parentPid=[int]$listener.ParentProcessId
$parent=Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $parentPid) -ErrorAction SilentlyContinue
$parentIsVenv=$false
if($parent){
    $parentIsVenv=([string]$parent.ExecutablePath -ieq $Python)
}

Write-Host ("STEP27_CURRENT_API_PID={0}" -f $listenerPid)
Write-Host ("STEP27_CURRENT_API_PARENT={0}" -f $parentPid)
Write-Host ("STEP27_CURRENT_API_PARENT_IS_VENV={0}" -f $parentIsVenv)

# Stop child first, then its venv launcher parent if it still exists.
Stop-Process -Id $listenerPid -Force -ErrorAction Stop
Start-Sleep -Seconds 1
if($parentIsVenv -and (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)){
    Stop-Process -Id $parentPid -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 2

if(Get-NetTCPConnection -LocalPort 8088 -State Listen -ErrorAction SilentlyContinue){
    throw "STEP27_ACTIVATE_PORT_8088_NOT_RELEASED"
}
Write-Host "STEP27_PORT_8088_RELEASED=PASS"

New-Item -ItemType Directory -Force -Path (Join-Path $Root "logs") | Out-Null
$new=Start-Process `
    -FilePath $Python `
    -ArgumentList @("-m","uvicorn","abutron.api:app","--host","127.0.0.1","--port","8088") `
    -WorkingDirectory $Root `
    -PassThru `
    -RedirectStandardOutput (Join-Path $Root "logs\api.out.log") `
    -RedirectStandardError (Join-Path $Root "logs\api.err.log")

$deadline=(Get-Date).AddSeconds(30)
$ok=$false
while((Get-Date) -lt $deadline){
    try{
        $h=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 3
        if($h.status -eq "ok"){$ok=$true;break}
    }catch{}
    Start-Sleep -Seconds 1
}
if(-not $ok){throw "STEP27_NEW_API_HEALTH_TIMEOUT"}

$openapi=Invoke-RestMethod "http://127.0.0.1:8088/openapi.json" -TimeoutSec 10
if($null -eq $openapi.paths.PSObject.Properties["/v1/admin/step27/summary"]){throw "STEP27_LIVE_ROUTE_MISSING"}
if($null -eq $openapi.paths.PSObject.Properties["/v1/customer/operations"]){throw "STEP27_LIVE_CUSTOMER_ROUTE_MISSING"}

Write-Host ("STEP27_VENV_LAUNCH_PID={0}" -f $new.Id)
Write-Host "STEP27_LIVE_OPENAPI=PASS"
Write-Host "LIVE_MONEY_AUTHORIZED=False"
Write-Host "STEP27_ACTIVATE=PASS"
