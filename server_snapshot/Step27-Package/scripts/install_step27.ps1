param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$PackageRoot = (Split-Path $PSScriptRoot)
)

$ErrorActionPreference="Stop"
$Stamp=Get-Date -Format "yyyyMMdd-HHmmss"
$StepRoot="C:\Abutron\Step27"
$LogDir=Join-Path $StepRoot "logs"
$VerifyDir=Join-Path $StepRoot "verify"
$BackupDir="C:\Abutron\Backups\PreStep27\$Stamp"
New-Item -ItemType Directory -Force -Path $LogDir,$VerifyDir,$BackupDir | Out-Null
$Log=Join-Path $LogDir "step27_install_$Stamp.log"

function Log([string]$m){
    $line="$(Get-Date -Format s) $m"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

Log "STEP27_INSTALL_START"

if(-not(Test-Path $Root)){throw "ROOT_NOT_FOUND=$Root"}
$Python=Join-Path $Root ".venv\Scripts\python.exe"
if(-not(Test-Path $Python)){throw "PYTHON_NOT_FOUND=$Python"}

# Gate: latest Step26A report must be PASS.
$Reports=Get-ChildItem (Join-Path $Root "certification\step26a\STEP26A_CERTIFICATION_*.json") -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
if(-not $Reports){throw "STEP27_GATE_FAIL=STEP26A_CERT_REPORT_MISSING"}
$Cert=Get-Content $Reports[0].FullName -Raw | ConvertFrom-Json
if($Cert.result -ne "PASS"){throw "STEP27_GATE_FAIL=STEP26A_NOT_PASS"}
Log "STEP27_GATE_STEP26A=PASS"

# Live money must remain disabled.
$envPath=Join-Path $Root ".env"
$envText=if(Test-Path $envPath){Get-Content $envPath -Raw}else{""}
foreach($danger in @(
    "ABUTRON_EXECUTION_ENABLED=true",
    "MT5_LIVE_TRADING=true",
    "MT5_MANAGEMENT_ENABLED=true",
    "CTRADER_LIVE_EXECUTION_ENABLED=true",
    "LIVE_MONEY_AUTHORIZED=true"
)){
    if($envText -match [regex]::Escape($danger)){throw "STEP27_SAFETY_ABORT=$danger"}
}
Log "STEP27_LIVE_SAFETY=PASS"

$health=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
if($health.status -ne "ok"){throw "STEP27_PRE_HEALTH_FAIL"}
if($health.execution_enabled -ne $false){throw "STEP27_EXECUTION_MUST_REMAIN_OFF"}
if($health.kronos_loaded -ne $true){throw "STEP27_KRONOS_NOT_LOADED"}
if($health.database -ne $true){throw "STEP27_DATABASE_NOT_HEALTHY"}
if($health.mt5.live_trading -ne $false){throw "STEP27_MT5_LIVE_MUST_REMAIN_OFF"}
if($health.mt5.management_enabled -ne $false){throw "STEP27_MT5_MANAGEMENT_MUST_REMAIN_OFF"}
Log "STEP27_PRE_HEALTH=PASS"

# Backup only touched files.
Copy-Item (Join-Path $Root "abutron\api.py") (Join-Path $BackupDir "api.py") -Force
foreach($f in @("step27_models.py","step27_service.py","step27_api.py")){
    $src=Join-Path $Root ("abutron\"+$f)
    if(Test-Path $src){Copy-Item $src (Join-Path $BackupDir $f) -Force}
}
if(Test-Path (Join-Path $Root "admin\step27.html")){
    Copy-Item (Join-Path $Root "admin\step27.html") (Join-Path $BackupDir "step27.html") -Force
}
Log ("STEP27_BACKUP=PASS:{0}" -f $BackupDir)

# Copy additive modules/admin page.
Copy-Item (Join-Path $PackageRoot "src\abutron\step27_models.py") (Join-Path $Root "abutron\step27_models.py") -Force
Copy-Item (Join-Path $PackageRoot "src\abutron\step27_service.py") (Join-Path $Root "abutron\step27_service.py") -Force
Copy-Item (Join-Path $PackageRoot "src\abutron\step27_api.py") (Join-Path $Root "abutron\step27_api.py") -Force
New-Item -ItemType Directory -Force -Path (Join-Path $Root "admin") | Out-Null
Copy-Item (Join-Path $PackageRoot "admin\step27.html") (Join-Path $Root "admin\step27.html") -Force
Log "STEP27_SOURCE_COPY=PASS"

# Patch router into API, BOM-safe and idempotent.
Push-Location $Root
try{
    & $Python (Join-Path $PackageRoot "scripts\patch_api.py") $Root
    if($LASTEXITCODE -ne 0){throw "STEP27_API_PATCH_FAIL"}
}finally{Pop-Location}
Log "STEP27_API_PATCH=PASS"

# Compile.
$Compile=Join-Path $VerifyDir "compile_step27.py"
@'
from pathlib import Path
import py_compile
root=Path(r"C:\Abutron\TradingPlatformV4")
for rel in (
    "abutron/step27_models.py",
    "abutron/step27_service.py",
    "abutron/step27_api.py",
    "abutron/api.py",
):
    py_compile.compile(str(root/rel),doraise=True)
print("STEP27_COMPILE=PASS")
'@ | Set-Content $Compile -Encoding UTF8

$oldPP=$env:PYTHONPATH;$env:PYTHONPATH=$Root
try{
    Push-Location $Root
    try{& $Python $Compile;if($LASTEXITCODE -ne 0){throw "STEP27_COMPILE_FAIL"}}
    finally{Pop-Location}
}finally{$env:PYTHONPATH=$oldPP}
Log "STEP27_COMPILE=PASS"

# Initialize additive tables by importing API.
$Db=Join-Path $VerifyDir "verify_step27_db.py"
@'
from pathlib import Path
import sys
root=Path(r"C:\Abutron\TradingPlatformV4")
sys.path.insert(0,str(root))
from sqlalchemy import inspect
from abutron.api import app
from abutron.platform_db import init_db,engine
init_db()
required={
"step27_crm_profiles",
"step27_crm_notes",
"step27_crm_tasks",
"step27_billing_invoices",
"step27_payment_events",
"step27_license_grants",
"step27_notification_preferences",
"step27_notification_outbox",
}
tables=set(inspect(engine).get_table_names())
missing=sorted(required-tables)
assert not missing,missing
print("STEP27_DB_TABLES=PASS")
'@ | Set-Content $Db -Encoding UTF8

$oldPP=$env:PYTHONPATH;$env:PYTHONPATH=$Root
try{
    Push-Location $Root
    try{& $Python $Db;if($LASTEXITCODE -ne 0){throw "STEP27_DB_INIT_FAIL"}}
    finally{Pop-Location}
}finally{$env:PYTHONPATH=$oldPP}
Log "STEP27_DB_TABLES=PASS"

# Static route/source contract.
$Routes=Join-Path $VerifyDir "verify_step27_routes.py"
@'
from pathlib import Path
import sys
root=Path(r"C:\Abutron\TradingPlatformV4")
sys.path.insert(0,str(root))
from abutron.api import app
routes={(m,r.path) for r in app.routes for m in (getattr(r,"methods",set()) or set())}
required={
("GET","/v1/customer/operations"),
("GET","/v1/customer/billing/invoices"),
("GET","/v1/customer/billing/invoices/{invoice_id}"),
("GET","/v1/customer/notification-preferences"),
("PATCH","/v1/customer/notification-preferences"),
("GET","/v1/admin/crm/customers"),
("GET","/v1/admin/crm/customers/{user_id}"),
("PATCH","/v1/admin/crm/customers/{user_id}"),
("POST","/v1/admin/crm/customers/{user_id}/notes"),
("POST","/v1/admin/crm/customers/{user_id}/tasks"),
("PATCH","/v1/admin/crm/tasks/{task_id}"),
("POST","/v1/admin/billing/invoices"),
("GET","/v1/admin/billing/invoices"),
("PATCH","/v1/admin/billing/invoices/{invoice_id}"),
("POST","/v1/admin/billing/invoices/{invoice_id}/record-payment"),
("POST","/v1/billing/webhook/generic"),
("POST","/v1/admin/licenses/grants"),
("POST","/v1/admin/licenses/grants/{grant_id}/approve"),
("POST","/v1/admin/licenses/grants/{grant_id}/revoke"),
("POST","/v1/admin/notifications"),
("GET","/v1/admin/notifications/outbox"),
("POST","/v1/admin/notifications/outbox/{outbox_id}/dispatch"),
("GET","/v1/admin/step27/summary"),
("GET","/admin/step27"),
}
missing=sorted(required-routes)
assert not missing,missing
print("STEP27_ROUTES=PASS")
'@ | Set-Content $Routes -Encoding UTF8

$oldPP=$env:PYTHONPATH;$env:PYTHONPATH=$Root
try{
    Push-Location $Root
    try{& $Python $Routes;if($LASTEXITCODE -ne 0){throw "STEP27_ROUTE_FAIL"}}
    finally{Pop-Location}
}finally{$env:PYTHONPATH=$oldPP}
Log "STEP27_ROUTES=PASS"

# Step27 must not invoke trade execution.
$forbidden=Select-String `
    -Path (Join-Path $Root "abutron\step27_*.py") `
    -Pattern "order_send|gateway\.order|svc\.gateway\.order|MT5Gateway|ctrader.*order|execute=True|LIVE_MONEY_AUTHORIZED\s*=\s*true" `
    -CaseSensitive:$false `
    -ErrorAction SilentlyContinue
if($forbidden){
    $forbidden|ForEach-Object{Log ("FORBIDDEN={0}:{1}:{2}" -f $_.Path,$_.LineNumber,$_.Line)}
    throw "STEP27_FORBIDDEN_EXECUTION_REFERENCE"
}
Log "STEP27_NO_EXECUTION_REFERENCE=PASS"

# Payment flow safety: payment handlers must explicitly report no auto-license/execution.
$apiText=Get-Content (Join-Path $Root "abutron\step27_api.py") -Raw
if($apiText -notmatch '"license_auto_activated": False'){throw "STEP27_PAYMENT_LICENSE_SEPARATION_FAIL"}
if($apiText -notmatch '"trading_execution_changed": False'){throw "STEP27_PAYMENT_EXECUTION_SEPARATION_FAIL"}
Log "STEP27_PAYMENT_LICENSE_SEPARATION=PASS"
Log "STEP27_EXTERNAL_PROVIDERS=GATED_UNCERTIFIED"
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP27_INSTALL=PASS"

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 27 INSTALL = PASS"
Write-Host " CRM/Billing/Licensing/Notifications installed"
Write-Host " External payment/email/push providers remain gated"
Write-Host " Live money authorized = FALSE"
Write-Host " Activate the API, then run certify_step27.ps1"
Write-Host "===================================================="
Write-Host ("Backup: {0}" -f $BackupDir)
Write-Host ("Log:    {0}" -f $Log)
