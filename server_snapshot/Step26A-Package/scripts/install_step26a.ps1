param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$PackageRoot = (Split-Path $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$StepRoot = "C:\Abutron\Step26A"
$LogDir = Join-Path $StepRoot "logs"
$BackupDir = "C:\Abutron\Backups\PreStep26A\$Stamp"
New-Item -ItemType Directory -Force -Path $LogDir,$BackupDir | Out-Null
$Log = Join-Path $LogDir "step26a_install_$Stamp.log"

function Log([string]$m){
    $line = "$(Get-Date -Format s) $m"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

Log "STEP26A_INSTALL_START"

if(-not(Test-Path $Root)){throw "ROOT_NOT_FOUND=$Root"}
$Python = Join-Path $Root ".venv\Scripts\python.exe"
if(-not(Test-Path $Python)){throw "PYTHON_NOT_FOUND=$Python"}

# Gate: Step23Q must already be certified.
$QReports = Get-ChildItem (Join-Path $Root "certification\step23q\STEP23Q_CERTIFICATION_*.json") -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
if(-not $QReports){throw "STEP26A_GATE_FAIL=STEP23Q_CERT_REPORT_MISSING"}
$Q = Get-Content $QReports[0].FullName -Raw | ConvertFrom-Json
if($Q.result -ne "PASS"){throw "STEP26A_GATE_FAIL=STEP23Q_NOT_PASS"}
Log "STEP26A_GATE_STEP23Q=PASS"

# Live money must remain disabled.
$envPath = Join-Path $Root ".env"
$envText = if(Test-Path $envPath){Get-Content $envPath -Raw}else{""}
foreach($danger in @(
    "ABUTRON_EXECUTION_ENABLED=true",
    "MT5_LIVE_TRADING=true",
    "MT5_MANAGEMENT_ENABLED=true",
    "CTRADER_LIVE_EXECUTION_ENABLED=true",
    "LIVE_MONEY_AUTHORIZED=true"
)){
    if($envText -match [regex]::Escape($danger)){throw "STEP26A_SAFETY_ABORT=$danger"}
}
Log "STEP26A_LIVE_SAFETY=PASS"

# Baseline health.
try{
    $health = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
    if($health.status -ne "ok"){throw "CORE_HEALTH_NOT_OK"}
    if($health.execution_enabled -ne $false){throw "CORE_EXECUTION_ENABLED"}
    Log "STEP26A_PRE_HEALTH=PASS"
}catch{
    throw "STEP26A_PRE_HEALTH_FAIL=$($_.Exception.Message)"
}

# Back up source that will be touched.
Copy-Item (Join-Path $Root "abutron\api.py") (Join-Path $BackupDir "api.py") -Force
if(Test-Path (Join-Path $Root "admin\step26a.html")){
    New-Item -ItemType Directory -Force -Path (Join-Path $BackupDir "admin") | Out-Null
    Copy-Item (Join-Path $Root "admin\step26a.html") (Join-Path $BackupDir "admin\step26a.html") -Force
}
Log "STEP26A_BACKUP=PASS:$BackupDir"

# Copy isolated Step26A backend modules.
Copy-Item (Join-Path $PackageRoot "src\abutron\step26a_models.py") (Join-Path $Root "abutron\step26a_models.py") -Force
Copy-Item (Join-Path $PackageRoot "src\abutron\step26a_api.py") (Join-Path $Root "abutron\step26a_api.py") -Force
New-Item -ItemType Directory -Force -Path (Join-Path $Root "admin") | Out-Null
Copy-Item (Join-Path $PackageRoot "admin\step26a.html") (Join-Path $Root "admin\step26a.html") -Force
Log "STEP26A_BACKEND_COPY=PASS"

# Copy mobile source without building or publishing it on the VPS.
$MobileDest = Join-Path $Root "mobile\AbutronMobile"
if(Test-Path $MobileDest){Remove-Item $MobileDest -Recurse -Force}
New-Item -ItemType Directory -Force -Path $MobileDest | Out-Null
Copy-Item (Join-Path $PackageRoot "mobile\AbutronMobile\*") $MobileDest -Recurse -Force
Log "STEP26A_MOBILE_SOURCE_COPY=PASS"

# Patch API router inclusion only.
& $Python (Join-Path $PackageRoot "scripts\patch_api.py") $Root
if($LASTEXITCODE -ne 0){throw "STEP26A_API_PATCH_FAIL"}
Log "STEP26A_API_PATCH=PASS"

# Compile all newly installed Python plus api.py.
$Verify = Join-Path $StepRoot "verify_compile.py"
@'
from pathlib import Path
import py_compile
root=Path(r"C:\Abutron\TradingPlatformV4")
targets=[
    root/"abutron"/"step26a_models.py",
    root/"abutron"/"step26a_api.py",
    root/"abutron"/"api.py",
]
for t in targets:
    py_compile.compile(str(t),doraise=True)
print("STEP26A_COMPILE=PASS")
'@ | Set-Content $Verify -Encoding UTF8

& $Python $Verify
if($LASTEXITCODE -ne 0){throw "STEP26A_COMPILE_FAIL"}
Log "STEP26A_COMPILE=PASS"

# Import API so Step26A models join Base.metadata, then create only missing tables.
$VerifyDb = Join-Path $StepRoot "verify_db.py"
@'
from sqlalchemy import inspect
from abutron.api import app
from abutron.platform_db import init_db, engine
init_db()
required={
    "step26a_devices",
    "step26a_notification_receipts",
    "step26a_support_tickets",
    "step26a_customer_preferences",
}
tables=set(inspect(engine).get_table_names())
missing=required-tables
assert not missing, missing
print("STEP26A_DB_TABLES=PASS")
'@ | Set-Content $VerifyDb -Encoding UTF8

Set-Location $Root
& $Python $VerifyDb
if($LASTEXITCODE -ne 0){throw "STEP26A_DB_INIT_FAIL"}
Log "STEP26A_DB_TABLES=PASS"

# Verify routes exist and trading routes were not introduced by Step26A.
$VerifyRoutes = Join-Path $StepRoot "verify_routes.py"
@'
from abutron.api import app
routes={(m,p) for r in app.routes for m in (getattr(r,"methods",set()) or set()) for p in [r.path]}
required={
("GET","/v1/mobile/bootstrap"),
("GET","/v1/customer/status"),
("PATCH","/v1/customer/profile"),
("GET","/v1/customer/accounts"),
("GET","/v1/customer/trades"),
("POST","/v1/devices/register"),
("GET","/v1/devices"),
("DELETE","/v1/devices/{device_id}"),
("GET","/v1/notifications"),
("PUT","/v1/notifications/{notification_id}/read"),
("POST","/v1/support/tickets"),
("GET","/v1/support/tickets"),
("GET","/v1/admin/customers/{user_id}"),
("GET","/v1/admin/support/tickets"),
("PUT","/v1/admin/support/tickets/{ticket_id}"),
("GET","/v1/admin/step26a/summary"),
("GET","/admin/step26a"),
}
missing=required-routes
assert not missing,missing
print("STEP26A_ROUTES=PASS")
'@ | Set-Content $VerifyRoutes -Encoding UTF8

& $Python $VerifyRoutes
if($LASTEXITCODE -ne 0){throw "STEP26A_ROUTES_FAIL"}
Log "STEP26A_ROUTES=PASS"

# Static source safety: Step26A modules must not issue broker/MT5 orders.
$forbidden = Select-String `
    -Path (Join-Path $Root "abutron\step26a_*.py") `
    -Pattern "order_send|gateway\.order|svc\.gateway\.order|MT5Gateway|ctrader.*order|execute=True" `
    -CaseSensitive:$false `
    -ErrorAction SilentlyContinue
if($forbidden){
    $forbidden | ForEach-Object {Log "FORBIDDEN=$($_.Path):$($_.LineNumber):$($_.Line)"}
    throw "STEP26A_FORBIDDEN_EXECUTION_REFERENCE"
}
Log "STEP26A_NO_BROKER_EXECUTION_REFERENCE=PASS"

Log "STEP26A_MOBILE_TRADING_MODE=READ_ONLY"
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP26A_INSTALL=PASS"

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 26A INSTALL = PASS"
Write-Host " Customer/Admin/Mobile foundation installed"
Write-Host " Mobile trading mode = READ_ONLY"
Write-Host " Live money authorized = FALSE"
Write-Host " Restart the platform, then run certify_step26a.ps1"
Write-Host "===================================================="
Write-Host "Log: $Log"
