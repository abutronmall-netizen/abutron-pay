param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$PackageRoot = "C:\Abutron\Step26A-Package"
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$StepRoot = "C:\Abutron\Step26A"
$LogDir = Join-Path $StepRoot "logs"
$VerifyDir = Join-Path $StepRoot "verify"
$CertDir = Join-Path $Root "certification\step26a"
New-Item -ItemType Directory -Force -Path $LogDir,$VerifyDir,$CertDir | Out-Null

$Log = Join-Path $LogDir "step26a_finalize_v1_0_2_$Stamp.log"
$Report = Join-Path $CertDir "STEP26A_CERTIFICATION_$Stamp.json"

function Log([string]$Message) {
    $line = "$(Get-Date -Format s) $Message"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

function Run-NativeChecked {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Name,
        [string]$WorkingDirectory = $Root
    )

    $stdout = Join-Path $LogDir "$($Name)_stdout_$Stamp.log"
    $stderr = Join-Path $LogDir "$($Name)_stderr_$Stamp.log"

    $p = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -Wait `
        -PassThru `
        -NoNewWindow

    if (Test-Path $stdout) {
        Get-Content $stdout | ForEach-Object { Log "$Name OUT: $_" }
    }
    if (Test-Path $stderr) {
        Get-Content $stderr | ForEach-Object { Log "$Name ERR: $_" }
    }

    Log "$Name`_EXIT_CODE=$($p.ExitCode)"
    if ($p.ExitCode -ne 0) {
        throw "$Name failed with exit code $($p.ExitCode)"
    }
}

Log "STEP26A_FINALIZE_V1_0_2_START"

if (-not (Test-Path $Root)) { throw "ROOT_NOT_FOUND=$Root" }
$Python = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path $Python)) { throw "PYTHON_NOT_FOUND=$Python" }

# ------------------------------------------------------------------
# 1. Preserve the certified Step23Q dependency.
# ------------------------------------------------------------------
$QReports = Get-ChildItem `
    (Join-Path $Root "certification\step23q\STEP23Q_CERTIFICATION_*.json") `
    -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

if (-not $QReports) { throw "STEP26A_GATE_FAIL=STEP23Q_CERT_REPORT_MISSING" }

$Q = Get-Content $QReports[0].FullName -Raw | ConvertFrom-Json
if ($Q.result -ne "PASS") { throw "STEP26A_GATE_FAIL=STEP23Q_NOT_PASS" }
Log "STEP26A_GATE_STEP23Q=PASS"

# ------------------------------------------------------------------
# 2. Runtime health/safety after restart.
# ------------------------------------------------------------------
$Health = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10

if ($Health.status -ne "ok") { throw "STEP26A_RUNTIME_HEALTH_FAIL" }
if ($Health.execution_enabled -ne $false) { throw "STEP26A_EXECUTION_MUST_REMAIN_OFF" }
if ($Health.kronos_loaded -ne $true) { throw "STEP26A_KRONOS_NOT_LOADED" }
if ($Health.database -ne $true) { throw "STEP26A_DATABASE_NOT_HEALTHY" }
if ($null -ne $Health.mt5) {
    if ($Health.mt5.live_trading -ne $false) { throw "STEP26A_MT5_LIVE_TRADING_MUST_REMAIN_OFF" }
    if ($Health.mt5.management_enabled -ne $false) { throw "STEP26A_MT5_MANAGEMENT_MUST_REMAIN_OFF" }
}

Log "STEP26A_RUNTIME_HEALTH=PASS"
Log "STEP26A_RUNTIME_SAFETY=PASS"

# ------------------------------------------------------------------
# 3. Required installed source.
# ------------------------------------------------------------------
$RequiredFiles = @(
    (Join-Path $Root "abutron\step26a_models.py"),
    (Join-Path $Root "abutron\step26a_api.py"),
    (Join-Path $Root "admin\step26a.html"),
    (Join-Path $Root "mobile\AbutronMobile\App.tsx"),
    (Join-Path $Root "mobile\AbutronMobile\src\api.ts"),
    (Join-Path $Root "mobile\AbutronMobile\package.json")
)
foreach ($File in $RequiredFiles) {
    if (-not (Test-Path $File)) { throw "STEP26A_REQUIRED_FILE_MISSING=$File" }
}
Log "STEP26A_INSTALLED_SOURCE=PASS"

# ------------------------------------------------------------------
# 4. Python verifier. It explicitly adds Root to sys.path, fixing the
#    verifier-launch problem seen in v1.0.1.
# ------------------------------------------------------------------
$Verifier = Join-Path $VerifyDir "step26a_finalize_verify_v1_0_2.py"

@'
from pathlib import Path
import json
import sys

ROOT = Path(r"C:\Abutron\TradingPlatformV4")
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from sqlalchemy import inspect
from abutron.api import app
from abutron.config import settings
from abutron.platform_db import engine

required_tables = {
    "step26a_devices",
    "step26a_notification_receipts",
    "step26a_support_tickets",
    "step26a_customer_preferences",
}

tables = set(inspect(engine).get_table_names())
missing_tables = sorted(required_tables - tables)
assert not missing_tables, f"missing tables: {missing_tables}"

routes = {
    (method, route.path)
    for route in app.routes
    for method in (getattr(route, "methods", set()) or set())
}

required_routes = {
    ("GET", "/v1/mobile/bootstrap"),
    ("GET", "/v1/customer/status"),
    ("PATCH", "/v1/customer/profile"),
    ("GET", "/v1/customer/accounts"),
    ("GET", "/v1/customer/trades"),
    ("POST", "/v1/devices/register"),
    ("GET", "/v1/devices"),
    ("DELETE", "/v1/devices/{device_id}"),
    ("GET", "/v1/notifications"),
    ("PUT", "/v1/notifications/{notification_id}/read"),
    ("POST", "/v1/support/tickets"),
    ("GET", "/v1/support/tickets"),
    ("GET", "/v1/admin/customers/{user_id}"),
    ("GET", "/v1/admin/support/tickets"),
    ("PUT", "/v1/admin/support/tickets/{ticket_id}"),
    ("GET", "/v1/admin/step26a/summary"),
    ("GET", "/admin/step26a"),
}

missing_routes = sorted(required_routes - routes)
assert not missing_routes, f"missing routes: {missing_routes}"
assert settings.execution_enabled is False, "execution_enabled must remain false"

api_source = (ROOT / "abutron" / "step26a_api.py").read_text(encoding="utf-8")
assert '"mobile_trading_mode": "READ_ONLY"' in api_source
assert '"order_entry": False' in api_source

mobile = (ROOT / "mobile" / "AbutronMobile" / "App.tsx").read_text(encoding="utf-8")
mobile_api = (ROOT / "mobile" / "AbutronMobile" / "src" / "api.ts").read_text(encoding="utf-8")
merged_mobile = mobile + "\n" + mobile_api

for forbidden in ("/v1/order", "Place Order", "order_send"):
    assert forbidden not in merged_mobile, forbidden

print("STEP26A_DB_CONTRACT=PASS")
print("STEP26A_ROUTE_CONTRACT=PASS")
print("STEP26A_READ_ONLY_CONTRACT=PASS")
print("STEP26A_MOBILE_SOURCE_CONTRACT=PASS")
print("STEP26A_EXECUTION_OFF=PASS")
'@ | Set-Content -Path $Verifier -Encoding UTF8

# Explicit PYTHONPATH makes imports deterministic even for verifier scripts
# located outside the project directory.
$OldPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = $Root
try {
    Run-NativeChecked `
        -FilePath $Python `
        -Arguments @($Verifier) `
        -Name "STEP26A_VERIFY" `
        -WorkingDirectory $Root
}
finally {
    $env:PYTHONPATH = $OldPythonPath
}

# ------------------------------------------------------------------
# 5. Static execution prohibition scan.
# ------------------------------------------------------------------
$Forbidden = Select-String `
    -Path (Join-Path $Root "abutron\step26a_*.py") `
    -Pattern "order_send|gateway\.order|svc\.gateway\.order|MT5Gateway|ctrader.*order|execute=True" `
    -CaseSensitive:$false `
    -ErrorAction SilentlyContinue

if ($Forbidden) {
    $Forbidden | ForEach-Object {
        Log "FORBIDDEN_EXECUTION_REFERENCE=$($_.Path):$($_.LineNumber):$($_.Line)"
    }
    throw "STEP26A_FORBIDDEN_EXECUTION_REFERENCE"
}
Log "STEP26A_NO_EXECUTION_REFERENCE=PASS"

# ------------------------------------------------------------------
# 6. HTTP auth-boundary smoke tests.
# Customer/admin API must reject anonymous access.
# ------------------------------------------------------------------
$Protected = @(
    "/v1/mobile/bootstrap",
    "/v1/customer/status",
    "/v1/devices",
    "/v1/support/tickets",
    "/v1/admin/step26a/summary"
)

foreach ($Path in $Protected) {
    $Uri = "http://127.0.0.1:8088$Path"
    try {
        $r = Invoke-WebRequest -Uri $Uri -Method GET -UseBasicParsing -TimeoutSec 10
        throw "STEP26A_AUTH_BOUNDARY_FAIL=$Path returned HTTP $($r.StatusCode)"
    }
    catch {
        $status = $null
        if ($_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        }
        if ($status -notin @(401,403)) {
            throw "STEP26A_AUTH_BOUNDARY_FAIL=$Path status=$status"
        }
        Log "STEP26A_AUTH_BOUNDARY=PASS:${Path}:$status"
    }
}

# Admin shell should load; its data APIs remain protected above.
$AdminPage = Invoke-WebRequest `
    -Uri "http://127.0.0.1:8088/admin/step26a" `
    -Method GET `
    -UseBasicParsing `
    -TimeoutSec 10

if ($AdminPage.StatusCode -ne 200) { throw "STEP26A_ADMIN_PAGE_FAIL" }
if ($AdminPage.Content -notmatch "ABUTRON STEP 26A ADMIN") { throw "STEP26A_ADMIN_PAGE_CONTENT_FAIL" }
Log "STEP26A_ADMIN_PAGE=PASS"

# ------------------------------------------------------------------
# 7. Final report.
# This certifies Step26A server/runtime + mobile source contract.
# Signed Android/iOS device acceptance remains a later release gate.
# ------------------------------------------------------------------
$ReportObject = [ordered]@{
    step = "26A"
    version = "1.0.2-finalize"
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    step23q_dependency = "PASS"
    runtime_health = "PASS"
    runtime_safety = "PASS"
    route_contract = "PASS"
    db_contract = "PASS"
    auth_boundary = "PASS"
    admin_console = "PASS"
    mobile_source = "PASS"
    mobile_trading_mode = "READ_ONLY"
    broker_execution_from_step26a = $false
    execution_enabled = $false
    live_money_authorized = $false
    signed_android_ios_acceptance = "DEFERRED_TO_STEP26B_RELEASE_GATES"
    result = "PASS"
}
$ReportObject | ConvertTo-Json -Depth 8 | Set-Content -Path $Report -Encoding UTF8

Log "STEP26A_ROUTE_DB_CONTRACT=PASS"
Log "STEP26A_MOBILE_SOURCE=PASS"
Log "STEP26A_ADMIN_CONSOLE=PASS"
Log "STEP26A_AUTH_BOUNDARY=PASS"
Log "STEP26A_MOBILE_READ_ONLY=PASS"
Log "STEP26A_NO_EXECUTION_REFERENCE=PASS"
Log "STEP26A_API_HEALTH=PASS"
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP26A=PASS"
Log "STEP26A_FINALIZE_V1_0_2=PASS"
Log "STEP26A_REPORT=$Report"

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 26A = CERTIFIED PASS"
Write-Host " Server/runtime contract = PASS"
Write-Host " Customer/Admin API = PASS"
Write-Host " Database tables = PASS"
Write-Host " Auth boundaries = PASS"
Write-Host " Mobile source contract = PASS"
Write-Host " Mobile trading = READ_ONLY"
Write-Host " Broker execution from Step26A = NONE"
Write-Host " Live money authorized = FALSE"
Write-Host ""
Write-Host " Signed Android/iOS acceptance remains a later release gate."
Write-Host "===================================================="
Write-Host "Report: $Report"
Write-Host "Log:    $Log"
