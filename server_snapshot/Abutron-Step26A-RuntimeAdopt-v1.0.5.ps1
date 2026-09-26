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

$Log = Join-Path $LogDir "step26a_runtime_adopt_v1_0_5_$Stamp.log"
$Report = Join-Path $CertDir "STEP26A_CERTIFICATION_$Stamp.json"
$Python = Join-Path $Root ".venv\Scripts\python.exe"
$PidFile = Join-Path $Root "data\platform_pids.txt"

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

function Get-LiveOpenApi {
    return Invoke-RestMethod "http://127.0.0.1:8088/openapi.json" -TimeoutSec 10
}

function Has-LivePath([object]$OpenApi,[string]$PathValue) {
    if($null -eq $OpenApi.paths){ return $false }
    return $null -ne $OpenApi.paths.PSObject.Properties[$PathValue]
}

function Wait-ForHealthyApi([int]$Seconds=30) {
    $deadline=(Get-Date).AddSeconds($Seconds)
    while((Get-Date) -lt $deadline) {
        try {
            $h=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 3
            if($h.status -eq "ok"){ return $true }
        } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
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

function Update-TrackedPid([int]$OldPid,[int]$NewPid) {
    New-Item -ItemType Directory -Force -Path (Split-Path $PidFile -Parent) | Out-Null

    $values=@()
    if(Test-Path $PidFile) {
        foreach($line in Get-Content $PidFile) {
            $trim=[string]$line
            if($trim.Trim() -match '^\d+$') {
                $values += [int]$trim.Trim()
            }
        }
    }

    $updated=@()
    $replaced=$false
    foreach($value in $values) {
        if($value -eq $OldPid) {
            if($updated -notcontains $NewPid){ $updated += $NewPid }
            $replaced=$true
        }
        elseif($updated -notcontains $value) {
            $updated += $value
        }
    }

    if(-not $replaced -and $updated -notcontains $NewPid) {
        $updated += $NewPid
    }

    $updated | Set-Content $PidFile
    Log ("STEP26A_PID_TRACKING=PASS:OLD={0}:NEW={1}" -f $OldPid,$NewPid)
}

Log "STEP26A_RUNTIME_ADOPT_V1_0_5_START"

if(-not(Test-Path $Python)){ throw "PYTHON_NOT_FOUND=$Python" }

# ------------------------------------------------------------------
# 1. Health and safety before any process change.
# ------------------------------------------------------------------
$health=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
if($health.status -ne "ok"){ throw "STEP26A_PRE_HEALTH_FAIL" }
if($health.execution_enabled -ne $false){ throw "STEP26A_EXECUTION_MUST_REMAIN_OFF" }
if($health.kronos_loaded -ne $true){ throw "STEP26A_KRONOS_NOT_LOADED" }
if($health.database -ne $true){ throw "STEP26A_DATABASE_NOT_HEALTHY" }
if($health.mt5.live_trading -ne $false){ throw "STEP26A_MT5_LIVE_MUST_REMAIN_OFF" }
if($health.mt5.management_enabled -ne $false){ throw "STEP26A_MT5_MANAGEMENT_MUST_REMAIN_OFF" }

Log "STEP26A_PRE_ADOPT_HEALTH=PASS"
Log "STEP26A_PRE_ADOPT_SAFETY=PASS"

# ------------------------------------------------------------------
# 2. Verify the disk application is Step26A-current.
# ------------------------------------------------------------------
Push-Location $Root
try {
    $diskOut=& $Python -c "from abutron.api import app; print('BOOTSTRAP='+str(any(r.path=='/v1/mobile/bootstrap' for r in app.routes))); print('ADMIN26A='+str(any(r.path=='/v1/admin/step26a/summary' for r in app.routes)))" 2>&1
    $diskCode=$LASTEXITCODE
}
finally { Pop-Location }

$diskOut | ForEach-Object { Log ("DISK: {0}" -f $_) }
if($diskCode -ne 0){ throw "STEP26A_DISK_IMPORT_FAIL" }
$diskText=$diskOut -join "`n"
if($diskText -notmatch "BOOTSTRAP=True"){ throw "STEP26A_DISK_BOOTSTRAP_MISSING" }
if($diskText -notmatch "ADMIN26A=True"){ throw "STEP26A_DISK_ADMIN_ROUTE_MISSING" }
Log "STEP26A_DISK_ROUTE_CONTRACT=PASS"

# ------------------------------------------------------------------
# 3. Inspect the live listener and OpenAPI.
# ------------------------------------------------------------------
$openapi=Get-LiveOpenApi
if([string]$openapi.info.title -ne "ABUTRON TRADING PLATFORM") {
    throw ("STEP26A_LIVE_8088_NOT_ABUTRON TITLE={0}" -f $openapi.info.title)
}

$owner=Get-PortOwner 8088
if(-not $owner){ throw "STEP26A_8088_OWNER_NOT_FOUND" }

Log ("STEP26A_8088_PID={0}" -f $owner.Pid)
Log ("STEP26A_8088_NAME={0}" -f $owner.Name)
Log ("STEP26A_8088_EXE={0}" -f $owner.ExecutablePath)
Log ("STEP26A_8088_PARENT_PID={0}" -f $owner.ParentProcessId)
Log ("STEP26A_8088_CMD={0}" -f $owner.CommandLine)

$bootstrapLive=Has-LivePath $openapi "/v1/mobile/bootstrap"
$adminLive=Has-LivePath $openapi "/v1/admin/step26a/summary"

$oldPid=[int]$owner.Pid
$newApiPid=$oldPid

if($bootstrapLive -and $adminLive) {
    Log "STEP26A_LIVE_OPENAPI_ALREADY_CURRENT=PASS"
}
else {
    Log "STEP26A_LIVE_OPENAPI_CURRENT=FAIL"

    # Exact application identity check. We intentionally accept either
    # global Python or venv Python ONLY when the command is the Abutron
    # Core Uvicorn app bound to localhost:8088.
    $cmd=[string]$owner.CommandLine
    $isVerifiedAbutronCore =
        ($owner.Name -ieq "python.exe") -and
        ($cmd -match '(?i)-m\s+uvicorn') -and
        ($cmd -match '(?i)abutron\.api:app') -and
        ($cmd -match '(?i)--host\s+127\.0\.0\.1') -and
        ($cmd -match '(?i)--port\s+8088')

    if(-not $isVerifiedAbutronCore) {
        throw ("STEP26A_ABORT_UNVERIFIED_8088_OWNER PID={0} CMD={1}" -f $owner.Pid,$cmd)
    }

    Log "STEP26A_STALE_ABUTRON_CORE_VERIFIED=PASS"
    Log ("STEP26A_STOPPING_STALE_CORE_PID={0}" -f $oldPid)

    Stop-Process -Id $oldPid -Force -ErrorAction Stop
    Start-Sleep -Seconds 4

    # If a watchdog/task automatically respawned the API, inspect it.
    $respawn=Get-PortOwner 8088
    if($respawn) {
        Log ("STEP26A_8088_AUTORESPAWN_PID={0}" -f $respawn.Pid)
        Log ("STEP26A_8088_AUTORESPAWN_EXE={0}" -f $respawn.ExecutablePath)
        Log ("STEP26A_8088_AUTORESPAWN_CMD={0}" -f $respawn.CommandLine)

        if(-not(Wait-ForHealthyApi 15)){ throw "STEP26A_AUTORESPAWN_HEALTH_FAIL" }
        $respawnOpenApi=Get-LiveOpenApi

        if((Has-LivePath $respawnOpenApi "/v1/mobile/bootstrap") -and
           (Has-LivePath $respawnOpenApi "/v1/admin/step26a/summary")) {
            $newApiPid=[int]$respawn.Pid
            Log "STEP26A_AUTORESPAWN_CURRENT=PASS"
        }
        else {
            throw ("STEP26A_AUTORESPAWN_STILL_STALE PID={0}" -f $respawn.Pid)
        }
    }
    else {
        Log "STEP26A_PORT_8088_RELEASED=PASS"

        $apiOut=Join-Path $Root "logs\api.out.log"
        $apiErr=Join-Path $Root "logs\api.err.log"

        $new=Start-Process `
            -FilePath $Python `
            -ArgumentList @("-m","uvicorn","abutron.api:app","--host","127.0.0.1","--port","8088") `
            -WorkingDirectory $Root `
            -PassThru `
            -RedirectStandardOutput $apiOut `
            -RedirectStandardError $apiErr

        $newApiPid=[int]$new.Id
        Log ("STEP26A_NEW_VENV_API_PID={0}" -f $newApiPid)

        if(-not(Wait-ForHealthyApi 30)) {
            if(Test-Path $apiErr) {
                Get-Content $apiErr -Tail 50 | ForEach-Object { Log ("API_ERR: {0}" -f $_) }
            }
            throw "STEP26A_NEW_VENV_API_HEALTH_TIMEOUT"
        }

        $liveOwner=Get-PortOwner 8088
        if(-not $liveOwner){ throw "STEP26A_NEW_8088_OWNER_MISSING" }
        Log ("STEP26A_NEW_8088_OWNER_PID={0}" -f $liveOwner.Pid)
        Log ("STEP26A_NEW_8088_OWNER_EXE={0}" -f $liveOwner.ExecutablePath)
        Log ("STEP26A_NEW_8088_OWNER_CMD={0}" -f $liveOwner.CommandLine)

        if([int]$liveOwner.Pid -ne $newApiPid) {
            throw ("STEP26A_NEW_API_PID_MISMATCH STARTED={0} LISTENER={1}" -f $newApiPid,$liveOwner.Pid)
        }

        $newApiPid=[int]$liveOwner.Pid
        $openapi=Get-LiveOpenApi
        if(-not(Has-LivePath $openapi "/v1/mobile/bootstrap")) {
            throw "STEP26A_LIVE_BOOTSTRAP_ROUTE_STILL_MISSING"
        }
        if(-not(Has-LivePath $openapi "/v1/admin/step26a/summary")) {
            throw "STEP26A_LIVE_ADMIN_ROUTE_STILL_MISSING"
        }
        Log "STEP26A_NEW_VENV_API_HEALTH=PASS"
        Log "STEP26A_LIVE_OPENAPI_CURRENT=PASS"
    }

    Update-TrackedPid -OldPid $oldPid -NewPid $newApiPid
}

# ------------------------------------------------------------------
# 4. Verify live OpenAPI again unconditionally.
# ------------------------------------------------------------------
$openapi2=Get-LiveOpenApi
$requiredLivePaths=@(
    "/v1/mobile/bootstrap",
    "/v1/customer/status",
    "/v1/customer/profile",
    "/v1/customer/accounts",
    "/v1/customer/trades",
    "/v1/devices/register",
    "/v1/devices",
    "/v1/notifications",
    "/v1/support/tickets",
    "/v1/admin/step26a/summary",
    "/admin/step26a"
)
foreach($pathValue in $requiredLivePaths) {
    if(-not(Has-LivePath $openapi2 $pathValue)) {
        throw ("STEP26A_LIVE_ROUTE_MISSING={0}" -f $pathValue)
    }
}
Log "STEP26A_LIVE_ROUTE_CONTRACT=PASS"

# ------------------------------------------------------------------
# 5. Authentication boundaries must now be 401/403/422, never 404.
# ------------------------------------------------------------------
Assert-Protected "/v1/mobile/bootstrap"
Assert-Protected "/v1/customer/status"
Assert-Protected "/v1/devices"
Assert-Protected "/v1/support/tickets"
Assert-Protected "/v1/admin/step26a/summary"
Log "STEP26A_AUTH_BOUNDARY=PASS"

# Admin HTML shell is allowed to load, while its APIs remain protected.
$adminPage=Invoke-WebRequest `
    -Uri "http://127.0.0.1:8088/admin/step26a" `
    -UseBasicParsing `
    -TimeoutSec 10
if($adminPage.StatusCode -ne 200){ throw "STEP26A_ADMIN_PAGE_HTTP_FAIL" }
if($adminPage.Content -notmatch "ABUTRON STEP 26A ADMIN"){ throw "STEP26A_ADMIN_PAGE_CONTENT_FAIL" }
Log "STEP26A_ADMIN_PAGE=PASS"

# ------------------------------------------------------------------
# 6. DB/source contract with deterministic import path.
# ------------------------------------------------------------------
$Verifier=Join-Path $VerifyDir "step26a_runtime_adopt_v1_0_5_verify.py"
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
missing_tables=sorted(required_tables-tables)
assert not missing_tables, missing_tables

required_paths={
    "/v1/mobile/bootstrap",
    "/v1/customer/status",
    "/v1/customer/profile",
    "/v1/customer/accounts",
    "/v1/customer/trades",
    "/v1/devices/register",
    "/v1/devices",
    "/v1/notifications",
    "/v1/support/tickets",
    "/v1/admin/step26a/summary",
    "/admin/step26a",
}
paths={r.path for r in app.routes}
missing_paths=sorted(required_paths-paths)
assert not missing_paths, missing_paths

assert settings.execution_enabled is False

api_source=(ROOT/"abutron"/"step26a_api.py").read_text(encoding="utf-8")
assert '"mobile_trading_mode": "READ_ONLY"' in api_source
assert '"order_entry": False' in api_source

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

$oldPythonPath=$env:PYTHONPATH
$env:PYTHONPATH=$Root
try {
    Push-Location $Root
    try {
        $verifyOut=& $Python $Verifier 2>&1
        $verifyCode=$LASTEXITCODE
    }
    finally { Pop-Location }
}
finally {
    $env:PYTHONPATH=$oldPythonPath
}

$verifyOut | ForEach-Object { Log ("STEP26A_VERIFY: {0}" -f $_) }
if($verifyCode -ne 0){ throw "STEP26A_VERIFY_FAIL" }
Log "STEP26A_VERIFY_EXIT_CODE=0"

# ------------------------------------------------------------------
# 7. No broker execution calls introduced by Step26A.
# ------------------------------------------------------------------
$forbiddenRefs=Select-String `
    -Path (Join-Path $Root "abutron\step26a_*.py") `
    -Pattern "order_send|gateway\.order|svc\.gateway\.order|MT5Gateway|ctrader.*order|execute=True" `
    -CaseSensitive:$false `
    -ErrorAction SilentlyContinue

if($forbiddenRefs){ throw "STEP26A_FORBIDDEN_EXECUTION_REFERENCE" }
Log "STEP26A_NO_EXECUTION_REFERENCE=PASS"

# ------------------------------------------------------------------
# 8. Final runtime safety.
# ------------------------------------------------------------------
$finalHealth=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
if($finalHealth.status -ne "ok"){ throw "STEP26A_FINAL_HEALTH_FAIL" }
if($finalHealth.execution_enabled -ne $false){ throw "STEP26A_FINAL_EXECUTION_ON" }
if($finalHealth.kronos_loaded -ne $true){ throw "STEP26A_FINAL_KRONOS_FAIL" }
if($finalHealth.database -ne $true){ throw "STEP26A_FINAL_DATABASE_FAIL" }
if($finalHealth.mt5.live_trading -ne $false){ throw "STEP26A_FINAL_MT5_LIVE_ON" }
if($finalHealth.mt5.management_enabled -ne $false){ throw "STEP26A_FINAL_MANAGEMENT_ON" }

$finalOwner=Get-PortOwner 8088
if(-not $finalOwner){ throw "STEP26A_FINAL_8088_OWNER_MISSING" }

Log "STEP26A_FINAL_HEALTH=PASS"
Log "STEP26A_FINAL_SAFETY=PASS"

[ordered]@{
    step="26A"
    version="1.0.5-runtime-adopt"
    timestamp=(Get-Date).ToUniversalTime().ToString("o")
    old_api_pid=$oldPid
    final_api_pid=[int]$finalOwner.Pid
    final_api_executable=[string]$finalOwner.ExecutablePath
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

Log "STEP26A_LIVE_OPENAPI=PASS"
Log "STEP26A_AUTH_BOUNDARY=PASS"
Log "STEP26A_ROUTE_DB_CONTRACT=PASS"
Log "STEP26A_MOBILE_SOURCE=PASS"
Log "STEP26A_ADMIN_CONSOLE=PASS"
Log "STEP26A_MOBILE_READ_ONLY=PASS"
Log "STEP26A_NO_EXECUTION_REFERENCE=PASS"
Log "STEP26A_API_HEALTH=PASS"
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP26A=PASS"
Log "STEP26A_RUNTIME_ADOPT_V1_0_5=PASS"
Log ("STEP26A_REPORT={0}" -f $Report)

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 26A = CERTIFIED PASS"
Write-Host " Live API synchronized with Step26A source"
Write-Host " DB + route contract = PASS"
Write-Host " Auth boundary = PASS"
Write-Host " Admin console = PASS"
Write-Host " Mobile source = PASS"
Write-Host " Mobile trading = READ_ONLY"
Write-Host " Live money authorized = FALSE"
Write-Host "===================================================="
Write-Host ("Report: {0}" -f $Report)
Write-Host ("Log:    {0}" -f $Log)
