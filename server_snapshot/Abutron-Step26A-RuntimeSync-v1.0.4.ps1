param(
    [string]$Root = "C:\Abutron\TradingPlatformV4"
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$StepRoot = "C:\Abutron\Step26A"
$LogDir = Join-Path $StepRoot "logs"
$CertDir = Join-Path $Root "certification\step26a"
New-Item -ItemType Directory -Force -Path $LogDir,$CertDir | Out-Null
$Log = Join-Path $LogDir "step26a_runtime_sync_v1_0_4_$Stamp.log"
$Report = Join-Path $CertDir "STEP26A_CERTIFICATION_$Stamp.json"

function Log([string]$Message) {
    $line = "$(Get-Date -Format s) $Message"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

function Get-LiveOpenApi {
    try {
        return Invoke-RestMethod "http://127.0.0.1:8088/openapi.json" -TimeoutSec 10
    } catch {
        throw "STEP26A_OPENAPI_UNAVAILABLE=$($_.Exception.Message)"
    }
}

function Test-LiveRoute([object]$OpenApi,[string]$Path) {
    if ($null -eq $OpenApi.paths) { return $false }
    return $null -ne $OpenApi.paths.PSObject.Properties[$Path]
}

function Get-PortOwner([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $conn) { return $null }
    $ownerPid = [int]$conn.OwningProcess
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$ownerPid" -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Pid = $ownerPid
        Name = if($proc){$proc.Name}else{""}
        ExecutablePath = if($proc){$proc.ExecutablePath}else{""}
        CommandLine = if($proc){$proc.CommandLine}else{""}
    }
}

function Wait-Api([int]$Seconds=30) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while((Get-Date) -lt $deadline) {
        try {
            $h = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 3
            if($h.status -eq "ok") { return $true }
        } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

Log "STEP26A_RUNTIME_SYNC_V1_0_4_START"

$Python = Join-Path $Root ".venv\Scripts\python.exe"
if(-not(Test-Path $Python)){throw "PYTHON_NOT_FOUND=$Python"}

# Safety first.
$health = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
if($health.status -ne "ok"){throw "STEP26A_HEALTH_NOT_OK"}
if($health.execution_enabled -ne $false){throw "STEP26A_EXECUTION_MUST_REMAIN_OFF"}
if($health.mt5.live_trading -ne $false){throw "STEP26A_MT5_LIVE_MUST_REMAIN_OFF"}
if($health.mt5.management_enabled -ne $false){throw "STEP26A_MT5_MANAGEMENT_MUST_REMAIN_OFF"}
Log "STEP26A_PRE_SYNC_HEALTH=PASS"
Log "STEP26A_PRE_SYNC_SAFETY=PASS"

# Disk contract.
Push-Location $Root
try {
    $diskRoutes = & $Python -c "from abutron.api import app; print(any(r.path=='/v1/mobile/bootstrap' for r in app.routes)); print(any(r.path=='/v1/admin/step26a/summary' for r in app.routes))"
    if($LASTEXITCODE -ne 0){throw "STEP26A_DISK_IMPORT_FAIL"}
}
finally {
    Pop-Location
}
$diskText = ($diskRoutes -join "`n")
if($diskText -notmatch "True"){throw "STEP26A_DISK_ROUTE_CONTRACT_FAIL"}
Log "STEP26A_DISK_ROUTE_CONTRACT=PASS"

# Live OpenAPI contract.
$openapi = Get-LiveOpenApi
$bootstrapLive = Test-LiveRoute $openapi "/v1/mobile/bootstrap"
$adminLive = Test-LiveRoute $openapi "/v1/admin/step26a/summary"

$owner = Get-PortOwner 8088
if($owner) {
    Log "STEP26A_8088_PID=$($owner.Pid)"
    Log "STEP26A_8088_NAME=$($owner.Name)"
    Log "STEP26A_8088_EXE=$($owner.ExecutablePath)"
    Log "STEP26A_8088_CMD=$($owner.CommandLine)"
}

if($bootstrapLive -and $adminLive) {
    Log "STEP26A_LIVE_OPENAPI_ALREADY_CURRENT=PASS"
}
else {
    Log "STEP26A_LIVE_OPENAPI_CURRENT=FAIL"
    if(-not $owner){throw "STEP26A_8088_NO_LISTENER_OWNER"}

    $cmd = [string]$owner.CommandLine
    $exe = [string]$owner.ExecutablePath

    # Only terminate a listener that is demonstrably the Abutron API.
    $verifiedAbutronApi =
        ($cmd -match "uvicorn") -and
        ($cmd -match "abutron\.api:app") -and
        (
            ($exe -like "$Root\.venv\Scripts\python.exe") -or
            ($cmd -match [regex]::Escape("$Root"))
        )

    if(-not $verifiedAbutronApi) {
        throw "STEP26A_ABORT_UNKNOWN_8088_OWNER PID=$($owner.Pid) CMD=$cmd"
    }

    Log "STEP26A_STALE_API_OWNER_VERIFIED=PASS"
    Log "STEP26A_STOPPING_STALE_API_PID=$($owner.Pid)"
    Stop-Process -Id $owner.Pid -Force -ErrorAction Stop
    Start-Sleep -Seconds 2

    # Confirm port released.
    $still = Get-NetTCPConnection -LocalPort 8088 -State Listen -ErrorAction SilentlyContinue
    if($still){throw "STEP26A_PORT_8088_NOT_RELEASED"}
    Log "STEP26A_PORT_8088_RELEASED=PASS"

    # Start only the API process from the certified platform root.
    $apiOut = Join-Path $Root "logs\api.out.log"
    $apiErr = Join-Path $Root "logs\api.err.log"
    $new = Start-Process `
        -FilePath $Python `
        -ArgumentList @("-m","uvicorn","abutron.api:app","--host","127.0.0.1","--port","8088") `
        -WorkingDirectory $Root `
        -PassThru `
        -RedirectStandardOutput $apiOut `
        -RedirectStandardError $apiErr

    Log "STEP26A_NEW_API_PID=$($new.Id)"

    if(-not(Wait-Api 30)) {
        if(Test-Path $apiErr){
            Get-Content $apiErr -Tail 40 | ForEach-Object { Log "API_ERR: $_" }
        }
        throw "STEP26A_NEW_API_HEALTH_TIMEOUT"
    }
    Log "STEP26A_NEW_API_HEALTH=PASS"

    # Re-check live OpenAPI from the actual listener.
    $openapi = Get-LiveOpenApi
    if(-not(Test-LiveRoute $openapi "/v1/mobile/bootstrap")) {
        throw "STEP26A_LIVE_BOOTSTRAP_ROUTE_STILL_MISSING"
    }
    if(-not(Test-LiveRoute $openapi "/v1/admin/step26a/summary")) {
        throw "STEP26A_LIVE_ADMIN_ROUTE_STILL_MISSING"
    }
    Log "STEP26A_LIVE_OPENAPI_CURRENT=PASS"
}

# Auth boundary test using HttpWebRequest exception status.
function Assert-Protected([string]$Path) {
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:8088$Path" -Method GET -UseBasicParsing -TimeoutSec 10
        throw "STEP26A_AUTH_BOUNDARY_FAIL=$Path HTTP=$($r.StatusCode)"
    } catch {
        $status = $null
        if($_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        }
        if($status -notin @(401,403,422)) {
            throw "STEP26A_AUTH_BOUNDARY_FAIL=$Path HTTP=$status"
        }
        Log ("STEP26A_AUTH_BOUNDARY=PASS:{0}:{1}" -f $Path,$status)
    }
}

Assert-Protected "/v1/mobile/bootstrap"
Assert-Protected "/v1/customer/status"
Assert-Protected "/v1/devices"
Assert-Protected "/v1/support/tickets"
Assert-Protected "/v1/admin/step26a/summary"

# Admin shell should be publicly loadable, while data APIs remain protected.
$adminPage = Invoke-WebRequest "http://127.0.0.1:8088/admin/step26a" -UseBasicParsing -TimeoutSec 10
if($adminPage.StatusCode -ne 200){throw "STEP26A_ADMIN_PAGE_HTTP_FAIL"}
if($adminPage.Content -notmatch "ABUTRON STEP 26A ADMIN"){throw "STEP26A_ADMIN_PAGE_CONTENT_FAIL"}
Log "STEP26A_ADMIN_PAGE=PASS"

# Database + source verifier with explicit sys.path.
$verify = Join-Path $StepRoot "verify\step26a_v1_0_4_verify.py"
New-Item -ItemType Directory -Force -Path (Split-Path $verify -Parent) | Out-Null
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
assert not(required_tables-tables), sorted(required_tables-tables)

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
assert not(required_paths-paths), sorted(required_paths-paths)
assert settings.execution_enabled is False

src=(ROOT/"abutron"/"step26a_api.py").read_text(encoding="utf-8")
assert '"mobile_trading_mode": "READ_ONLY"' in src
assert '"order_entry": False' in src

print("STEP26A_DB_CONTRACT=PASS")
print("STEP26A_ROUTE_CONTRACT=PASS")
print("STEP26A_READ_ONLY_CONTRACT=PASS")
print("STEP26A_EXECUTION_OFF=PASS")
'@ | Set-Content $verify -Encoding UTF8

$oldPP=$env:PYTHONPATH
$env:PYTHONPATH=$Root
try {
    Push-Location $Root
    try {
        $verifyOut=& $Python $verify 2>&1
        $code=$LASTEXITCODE
    } finally { Pop-Location }
} finally {
    $env:PYTHONPATH=$oldPP
}
$verifyOut | ForEach-Object { Log "STEP26A_VERIFY: $_" }
if($code -ne 0){throw "STEP26A_VERIFY_FAIL"}
Log "STEP26A_VERIFY_EXIT_CODE=0"

# Static execution scan.
$forbidden=Select-String `
    -Path (Join-Path $Root "abutron\step26a_*.py") `
    -Pattern "order_send|gateway\.order|svc\.gateway\.order|MT5Gateway|ctrader.*order|execute=True" `
    -CaseSensitive:$false `
    -ErrorAction SilentlyContinue

if($forbidden){throw "STEP26A_FORBIDDEN_EXECUTION_REFERENCE"}
Log "STEP26A_NO_EXECUTION_REFERENCE=PASS"

# Final runtime health after sync.
$health2=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
if($health2.status -ne "ok"){throw "STEP26A_FINAL_HEALTH_FAIL"}
if($health2.execution_enabled -ne $false){throw "STEP26A_FINAL_EXECUTION_ON"}
if($health2.mt5.live_trading -ne $false){throw "STEP26A_FINAL_MT5_LIVE_ON"}
if($health2.mt5.management_enabled -ne $false){throw "STEP26A_FINAL_MT5_MANAGEMENT_ON"}
Log "STEP26A_FINAL_HEALTH=PASS"
Log "STEP26A_FINAL_SAFETY=PASS"

$finalOwner=Get-PortOwner 8088

[ordered]@{
    step="26A"
    version="1.0.4-runtime-sync"
    timestamp=(Get-Date).ToUniversalTime().ToString("o")
    live_openapi="PASS"
    auth_boundary="PASS"
    db_contract="PASS"
    route_contract="PASS"
    admin_console="PASS"
    mobile_source="PASS"
    mobile_trading_mode="READ_ONLY"
    no_execution_reference=$true
    execution_enabled=$false
    live_money_authorized=$false
    api_pid=if($finalOwner){$finalOwner.Pid}else{$null}
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
Log "STEP26A_RUNTIME_SYNC_V1_0_4=PASS"
Log "STEP26A_REPORT=$Report"

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
Write-Host "Report: $Report"
Write-Host "Log:    $Log"
