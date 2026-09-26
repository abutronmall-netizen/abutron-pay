param(
    [string]$Root = "C:\Abutron\TradingPlatformV4"
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$StepRoot = "C:\Abutron\Step26A"
$LogDir = Join-Path $StepRoot "logs"
$VerifyDir = Join-Path $StepRoot "verify"
$CertDir = Join-Path $Root "certification\step26a"
New-Item -ItemType Directory -Force -Path $LogDir,$VerifyDir,$CertDir | Out-Null

$Log = Join-Path $LogDir "step26a_runtime_verify_v1_0_6_$Stamp.log"
$Report = Join-Path $CertDir "STEP26A_CERTIFICATION_$Stamp.json"
$Python = Join-Path $Root ".venv\Scripts\python.exe"

function Log([string]$Message) {
    $line = "$(Get-Date -Format s) $Message"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

function Get-PortOwner([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if(-not $conn){ return $null }

    $ownerPid = [int]$conn.OwningProcess
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Pid = $ownerPid
        Name = if($proc){[string]$proc.Name}else{""}
        ExecutablePath = if($proc){[string]$proc.ExecutablePath}else{""}
        CommandLine = if($proc){[string]$proc.CommandLine}else{""}
        ParentProcessId = if($proc){[int]$proc.ParentProcessId}else{0}
    }
}

function Has-LivePath([object]$OpenApi,[string]$PathValue) {
    if($null -eq $OpenApi.paths){ return $false }
    return $null -ne $OpenApi.paths.PSObject.Properties[$PathValue]
}

function Assert-Protected([string]$PathValue) {
    try {
        $r=Invoke-WebRequest `
            -Uri ("http://127.0.0.1:8088{0}" -f $PathValue) `
            -Method GET `
            -UseBasicParsing `
            -TimeoutSec 10
        throw ("STEP26A_AUTH_BOUNDARY_FAIL={0} HTTP={1}" -f $PathValue,$r.StatusCode)
    }
    catch {
        $status=$null
        if($_.Exception.Response) {
            try { $status=[int]$_.Exception.Response.StatusCode } catch {}
        }
        if($status -notin @(401,403,422)) {
            throw ("STEP26A_AUTH_BOUNDARY_FAIL={0} HTTP={1}" -f $PathValue,$status)
        }
        Log ("STEP26A_AUTH_BOUNDARY=PASS:{0}:{1}" -f $PathValue,$status)
    }
}

function Run-PythonChecked([string]$ScriptPath,[string]$Name) {
    $stdout=Join-Path $LogDir ("{0}_stdout_{1}.log" -f $Name,$Stamp)
    $stderr=Join-Path $LogDir ("{0}_stderr_{1}.log" -f $Name,$Stamp)

    $oldPP=$env:PYTHONPATH
    $env:PYTHONPATH=$Root
    try {
        $p=Start-Process `
            -FilePath $Python `
            -ArgumentList @($ScriptPath) `
            -WorkingDirectory $Root `
            -RedirectStandardOutput $stdout `
            -RedirectStandardError $stderr `
            -Wait `
            -PassThru `
            -NoNewWindow
    }
    finally {
        $env:PYTHONPATH=$oldPP
    }

    if(Test-Path $stdout){
        Get-Content $stdout | ForEach-Object { Log ("{0}: {1}" -f $Name,$_) }
    }
    if(Test-Path $stderr){
        Get-Content $stderr | ForEach-Object { Log ("{0}_STDERR: {1}" -f $Name,$_) }
    }

    Log ("{0}_EXIT_CODE={1}" -f $Name,$p.ExitCode)
    if($p.ExitCode -ne 0){ throw ("{0}_FAIL" -f $Name) }
}

Log "STEP26A_RUNTIME_VERIFY_V1_0_6_START"

if(-not(Test-Path $Python)){ throw "PYTHON_NOT_FOUND=$Python" }

# 1. Safety and platform health.
$health=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
if($health.status -ne "ok"){ throw "STEP26A_RUNTIME_HEALTH_FAIL" }
if($health.execution_enabled -ne $false){ throw "STEP26A_EXECUTION_MUST_REMAIN_OFF" }
if($health.kronos_loaded -ne $true){ throw "STEP26A_KRONOS_NOT_LOADED" }
if($health.database -ne $true){ throw "STEP26A_DATABASE_NOT_HEALTHY" }
if($health.mt5.live_trading -ne $false){ throw "STEP26A_MT5_LIVE_MUST_REMAIN_OFF" }
if($health.mt5.management_enabled -ne $false){ throw "STEP26A_MT5_MANAGEMENT_MUST_REMAIN_OFF" }

Log "STEP26A_RUNTIME_HEALTH=PASS"
Log "STEP26A_RUNTIME_SAFETY=PASS"

# 2. Inspect the actual listener. Do not modify it.
$owner=Get-PortOwner 8088
if(-not $owner){ throw "STEP26A_8088_OWNER_NOT_FOUND" }

Log ("STEP26A_8088_PID={0}" -f $owner.Pid)
Log ("STEP26A_8088_PARENT_PID={0}" -f $owner.ParentProcessId)
Log ("STEP26A_8088_NAME={0}" -f $owner.Name)
Log ("STEP26A_8088_EXE={0}" -f $owner.ExecutablePath)
Log ("STEP26A_8088_CMD={0}" -f $owner.CommandLine)

$parent=Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $owner.ParentProcessId) -ErrorAction SilentlyContinue
if($parent){
    Log ("STEP26A_PARENT_NAME={0}" -f $parent.Name)
    Log ("STEP26A_PARENT_EXE={0}" -f $parent.ExecutablePath)
    Log ("STEP26A_PARENT_CMD={0}" -f $parent.CommandLine)
}
else {
    Log ("STEP26A_PARENT_PROCESS_EXITED_OR_UNAVAILABLE={0}" -f $owner.ParentProcessId)
}

# The listener must at least be the Abutron API command.
$cmd=[string]$owner.CommandLine
$isAbutronCore =
    ($owner.Name -ieq "python.exe") -and
    ($cmd -match '(?i)-m\s+uvicorn') -and
    ($cmd -match '(?i)abutron\.api:app') -and
    ($cmd -match '(?i)--host\s+127\.0\.0\.1') -and
    ($cmd -match '(?i)--port\s+8088')

if(-not $isAbutronCore){
    throw ("STEP26A_8088_NOT_VERIFIED_ABUTRON_CORE PID={0}" -f $owner.Pid)
}
Log "STEP26A_8088_ABUTRON_CORE_IDENTITY=PASS"

# 3. This is the decisive test: the LIVE server, not only source import.
$openapi=Invoke-RestMethod "http://127.0.0.1:8088/openapi.json" -TimeoutSec 10
if([string]$openapi.info.title -ne "ABUTRON TRADING PLATFORM"){
    throw ("STEP26A_OPENAPI_TITLE_FAIL={0}" -f $openapi.info.title)
}

$requiredLivePaths=@(
    "/v1/mobile/bootstrap",
    "/v1/customer/status",
    "/v1/customer/profile",
    "/v1/customer/accounts",
    "/v1/customer/trades",
    "/v1/devices/register",
    "/v1/devices",
    "/v1/notifications",
    "/v1/notifications/{notification_id}/read",
    "/v1/support/tickets",
    "/v1/admin/customers/{user_id}",
    "/v1/admin/support/tickets",
    "/v1/admin/support/tickets/{ticket_id}",
    "/v1/admin/step26a/summary",
    "/admin/step26a"
)

$missingLive=@()
foreach($pathValue in $requiredLivePaths){
    if(-not(Has-LivePath $openapi $pathValue)){
        $missingLive += $pathValue
    }
}

if($missingLive.Count -gt 0){
    foreach($m in $missingLive){ Log ("STEP26A_LIVE_ROUTE_MISSING={0}" -f $m) }
    throw "STEP26A_LIVE_OPENAPI_STILL_STALE"
}

Log "STEP26A_LIVE_OPENAPI=PASS"
Log "STEP26A_LIVE_ROUTE_CONTRACT=PASS"

# 4. Authentication boundary. A protected endpoint must not be 404.
Assert-Protected "/v1/mobile/bootstrap"
Assert-Protected "/v1/customer/status"
Assert-Protected "/v1/devices"
Assert-Protected "/v1/support/tickets"
Assert-Protected "/v1/admin/step26a/summary"
Log "STEP26A_AUTH_BOUNDARY=PASS"

# 5. Admin shell.
$admin=Invoke-WebRequest `
    -Uri "http://127.0.0.1:8088/admin/step26a" `
    -UseBasicParsing `
    -TimeoutSec 10

if($admin.StatusCode -ne 200){ throw "STEP26A_ADMIN_PAGE_HTTP_FAIL" }
if($admin.Content -notmatch "ABUTRON STEP 26A ADMIN"){ throw "STEP26A_ADMIN_PAGE_CONTENT_FAIL" }
Log "STEP26A_ADMIN_PAGE=PASS"

# 6. DB/source/mobile verifier with deterministic import path.
$Verifier=Join-Path $VerifyDir "step26a_runtime_verify_v1_0_6.py"
@'
from pathlib import Path
import sys

ROOT=Path(r"C:\Abutron\TradingPlatformV4")
sys.path.insert(0,str(ROOT))

from sqlalchemy import inspect
from abutron.api import app
from abutron.config import settings
from abutron.platform_db import engine

required_tables={
    "step26a_devices",
    "step26a_notification_receipts",
    "step26a_support_tickets",
    "step26a_customer_preferences",
}
tables=set(inspect(engine).get_table_names())
missing=sorted(required_tables-tables)
assert not missing, missing

required_paths={
    "/v1/mobile/bootstrap",
    "/v1/customer/status",
    "/v1/customer/profile",
    "/v1/customer/accounts",
    "/v1/customer/trades",
    "/v1/devices/register",
    "/v1/devices",
    "/v1/notifications",
    "/v1/notifications/{notification_id}/read",
    "/v1/support/tickets",
    "/v1/admin/customers/{user_id}",
    "/v1/admin/support/tickets",
    "/v1/admin/support/tickets/{ticket_id}",
    "/v1/admin/step26a/summary",
    "/admin/step26a",
}
paths={r.path for r in app.routes}
missing_paths=sorted(required_paths-paths)
assert not missing_paths, missing_paths
assert settings.execution_enabled is False

api=(ROOT/"abutron"/"step26a_api.py").read_text(encoding="utf-8")
assert '"mobile_trading_mode": "READ_ONLY"' in api
assert '"order_entry": False' in api

mobile=(ROOT/"mobile"/"AbutronMobile"/"App.tsx").read_text(encoding="utf-8")
mobile_api=(ROOT/"mobile"/"AbutronMobile"/"src"/"api.ts").read_text(encoding="utf-8")
merged=mobile+"\n"+mobile_api
for forbidden in ("/v1/order","Place Order","order_send"):
    assert forbidden not in merged, forbidden

print("STEP26A_DB_CONTRACT=PASS")
print("STEP26A_ROUTE_CONTRACT=PASS")
print("STEP26A_READ_ONLY_CONTRACT=PASS")
print("STEP26A_MOBILE_SOURCE_CONTRACT=PASS")
print("STEP26A_EXECUTION_OFF=PASS")
'@ | Set-Content $Verifier -Encoding UTF8

Run-PythonChecked -ScriptPath $Verifier -Name "STEP26A_VERIFY"

# 7. No broker execution references introduced by Step26A.
$forbidden=Select-String `
    -Path (Join-Path $Root "abutron\step26a_*.py") `
    -Pattern "order_send|gateway\.order|svc\.gateway\.order|MT5Gateway|ctrader.*order|execute=True" `
    -CaseSensitive:$false `
    -ErrorAction SilentlyContinue

if($forbidden){ throw "STEP26A_FORBIDDEN_EXECUTION_REFERENCE" }
Log "STEP26A_NO_EXECUTION_REFERENCE=PASS"

# 8. Final health.
$final=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
if($final.status -ne "ok"){ throw "STEP26A_FINAL_HEALTH_FAIL" }
if($final.execution_enabled -ne $false){ throw "STEP26A_FINAL_EXECUTION_ON" }
if($final.mt5.live_trading -ne $false){ throw "STEP26A_FINAL_MT5_LIVE_ON" }
if($final.mt5.management_enabled -ne $false){ throw "STEP26A_FINAL_MANAGEMENT_ON" }

Log "STEP26A_FINAL_HEALTH=PASS"
Log "STEP26A_FINAL_SAFETY=PASS"

[ordered]@{
    step="26A"
    version="1.0.6-runtime-verify"
    timestamp=(Get-Date).ToUniversalTime().ToString("o")
    live_api_pid=[int]$owner.Pid
    live_api_parent_pid=[int]$owner.ParentProcessId
    live_api_executable=[string]$owner.ExecutablePath
    live_openapi="PASS"
    auth_boundary="PASS"
    db_contract="PASS"
    route_contract="PASS"
    admin_console="PASS"
    mobile_source="PASS"
    mobile_trading_mode="READ_ONLY"
    broker_execution_from_step26a=$false
    execution_enabled=$false
    live_money_authorized=$false
    signed_android_ios_acceptance="DEFERRED_TO_STEP26B_RELEASE_GATES"
    result="PASS"
}|ConvertTo-Json -Depth 8|Set-Content $Report -Encoding UTF8

Log "STEP26A_ROUTE_DB_CONTRACT=PASS"
Log "STEP26A_MOBILE_SOURCE=PASS"
Log "STEP26A_ADMIN_CONSOLE=PASS"
Log "STEP26A_MOBILE_READ_ONLY=PASS"
Log "STEP26A_API_HEALTH=PASS"
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP26A=PASS"
Log "STEP26A_RUNTIME_VERIFY_V1_0_6=PASS"
Log ("STEP26A_REPORT={0}" -f $Report)

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 26A = CERTIFIED PASS"
Write-Host " Live OpenAPI = PASS"
Write-Host " Auth boundary = PASS"
Write-Host " DB + route contract = PASS"
Write-Host " Admin console = PASS"
Write-Host " Mobile source = PASS"
Write-Host " Mobile trading = READ_ONLY"
Write-Host " Live money authorized = FALSE"
Write-Host "===================================================="
Write-Host ("Report: {0}" -f $Report)
Write-Host ("Log:    {0}" -f $Log)
