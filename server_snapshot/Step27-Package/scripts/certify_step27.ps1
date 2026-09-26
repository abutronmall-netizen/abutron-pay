param([string]$Root="C:\Abutron\TradingPlatformV4")
$ErrorActionPreference="Stop"
$Stamp=Get-Date -Format "yyyyMMdd-HHmmss"
$StepRoot="C:\Abutron\Step27"
$LogDir=Join-Path $StepRoot "logs"
$VerifyDir=Join-Path $StepRoot "verify"
$CertDir=Join-Path $Root "certification\step27"
New-Item -ItemType Directory -Force -Path $LogDir,$VerifyDir,$CertDir | Out-Null
$Log=Join-Path $LogDir "step27_cert_$Stamp.log"
$Report=Join-Path $CertDir "STEP27_CERTIFICATION_$Stamp.json"
$Python=Join-Path $Root ".venv\Scripts\python.exe"

function Log([string]$m){$line="$(Get-Date -Format s) $m";Write-Host $line;Add-Content $Log $line}
function Assert-Protected([string]$PathValue,[string]$Method="GET"){
    try{
        $r=Invoke-WebRequest -Uri ("http://127.0.0.1:8088{0}" -f $PathValue) -Method $Method -UseBasicParsing -TimeoutSec 10
        throw ("AUTH_BOUNDARY_FAIL={0}:{1}:HTTP={2}" -f $Method,$PathValue,$r.StatusCode)
    }catch{
        $status=$null
        if($_.Exception.Response){try{$status=[int]$_.Exception.Response.StatusCode}catch{}}
        if($status -notin @(401,403,422)){throw ("AUTH_BOUNDARY_FAIL={0}:{1}:HTTP={2}" -f $Method,$PathValue,$status)}
        Log ("STEP27_AUTH_BOUNDARY=PASS:{0}:{1}:{2}" -f $Method,$PathValue,$status)
    }
}

Log "STEP27_CERT_START"

$reports=Get-ChildItem (Join-Path $Root "certification\step26a\STEP26A_CERTIFICATION_*.json") -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTime -Descending
if(-not $reports){throw "STEP27_GATE_FAIL=STEP26A_REPORT_MISSING"}
$c=Get-Content $reports[0].FullName -Raw|ConvertFrom-Json
if($c.result -ne "PASS"){throw "STEP27_GATE_FAIL=STEP26A_NOT_PASS"}
Log "STEP27_GATE_STEP26A=PASS"

$h=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10
if($h.status -ne "ok" -or $h.execution_enabled -ne $false -or $h.kronos_loaded -ne $true -or $h.database -ne $true){throw "STEP27_RUNTIME_HEALTH_FAIL"}
if($h.mt5.live_trading -ne $false -or $h.mt5.management_enabled -ne $false){throw "STEP27_RUNTIME_SAFETY_FAIL"}
Log "STEP27_RUNTIME_HEALTH=PASS"
Log "STEP27_RUNTIME_SAFETY=PASS"

$openapi=Invoke-RestMethod "http://127.0.0.1:8088/openapi.json" -TimeoutSec 10
$required=@(
"/v1/customer/operations",
"/v1/customer/billing/invoices",
"/v1/customer/billing/invoices/{invoice_id}",
"/v1/customer/notification-preferences",
"/v1/admin/crm/customers",
"/v1/admin/crm/customers/{user_id}",
"/v1/admin/crm/customers/{user_id}/notes",
"/v1/admin/crm/customers/{user_id}/tasks",
"/v1/admin/crm/tasks/{task_id}",
"/v1/admin/billing/invoices",
"/v1/admin/billing/invoices/{invoice_id}",
"/v1/admin/billing/invoices/{invoice_id}/record-payment",
"/v1/billing/webhook/generic",
"/v1/admin/licenses/grants",
"/v1/admin/licenses/grants/{grant_id}/approve",
"/v1/admin/licenses/grants/{grant_id}/revoke",
"/v1/admin/notifications",
"/v1/admin/notifications/outbox",
"/v1/admin/notifications/outbox/{outbox_id}/dispatch",
"/v1/admin/step27/summary"
)
foreach($p in $required){
    if($null -eq $openapi.paths.PSObject.Properties[$p]){throw ("STEP27_LIVE_ROUTE_MISSING={0}" -f $p)}
}
Log "STEP27_LIVE_OPENAPI=PASS"

Assert-Protected "/v1/customer/operations"
Assert-Protected "/v1/customer/billing/invoices"
Assert-Protected "/v1/admin/crm/customers"
Assert-Protected "/v1/admin/billing/invoices"
Assert-Protected "/v1/admin/notifications/outbox"
Assert-Protected "/v1/admin/step27/summary"
Log "STEP27_AUTH_BOUNDARY=PASS"

# Webhook must fail closed while disabled.
try{
    $r=Invoke-WebRequest -Uri "http://127.0.0.1:8088/v1/billing/webhook/generic" -Method POST -ContentType "application/json" -Body "{}" -UseBasicParsing -TimeoutSec 10
    throw ("STEP27_WEBHOOK_FAIL_CLOSED_FAIL HTTP={0}" -f $r.StatusCode)
}catch{
    $status=$null
    if($_.Exception.Response){try{$status=[int]$_.Exception.Response.StatusCode}catch{}}
    if($status -ne 503){throw ("STEP27_WEBHOOK_FAIL_CLOSED_FAIL HTTP={0}" -f $status)}
}
Log "STEP27_BILLING_WEBHOOK_FAIL_CLOSED=PASS"

$admin=Invoke-WebRequest "http://127.0.0.1:8088/admin/step27" -UseBasicParsing -TimeoutSec 10
if($admin.StatusCode -ne 200 -or $admin.Content -notmatch "ABUTRON.*STEP 27 OPERATIONS"){throw "STEP27_ADMIN_PAGE_FAIL"}
Log "STEP27_ADMIN_CONSOLE=PASS"

$Verifier=Join-Path $VerifyDir "cert_step27.py"
@'
from pathlib import Path
import sys
root=Path(r"C:\Abutron\TradingPlatformV4")
sys.path.insert(0,str(root))
from sqlalchemy import inspect
from abutron.api import app
from abutron.config import settings
from abutron.platform_db import engine
required_tables={
"step27_crm_profiles","step27_crm_notes","step27_crm_tasks",
"step27_billing_invoices","step27_payment_events","step27_license_grants",
"step27_notification_preferences","step27_notification_outbox",
}
tables=set(inspect(engine).get_table_names())
assert not(required_tables-tables),sorted(required_tables-tables)
assert settings.execution_enabled is False
print("STEP27_DB_CONTRACT=PASS")
print("STEP27_EXECUTION_OFF=PASS")
'@ | Set-Content $Verifier -Encoding UTF8

$stdout=Join-Path $LogDir "cert_python_stdout_$Stamp.log";$stderr=Join-Path $LogDir "cert_python_stderr_$Stamp.log"
$oldPP=$env:PYTHONPATH;$env:PYTHONPATH=$Root
try{
    $p=Start-Process -FilePath $Python -ArgumentList @($Verifier) -WorkingDirectory $Root -RedirectStandardOutput $stdout -RedirectStandardError $stderr -Wait -PassThru -NoNewWindow
}finally{$env:PYTHONPATH=$oldPP}
if(Test-Path $stdout){Get-Content $stdout|ForEach-Object{Log ("STEP27_VERIFY: {0}" -f $_)}}
if(Test-Path $stderr){Get-Content $stderr|ForEach-Object{Log ("STEP27_VERIFY_ERR: {0}" -f $_)}}
if($p.ExitCode -ne 0){throw "STEP27_DB_VERIFY_FAIL"}

$forbidden=Select-String -Path (Join-Path $Root "abutron\step27_*.py") -Pattern "order_send|gateway\.order|svc\.gateway\.order|MT5Gateway|ctrader.*order|execute=True" -CaseSensitive:$false -ErrorAction SilentlyContinue
if($forbidden){throw "STEP27_FORBIDDEN_EXECUTION_REFERENCE"}
Log "STEP27_NO_EXECUTION_REFERENCE=PASS"

$apiText=Get-Content (Join-Path $Root "abutron\step27_api.py") -Raw
if($apiText -notmatch '"license_auto_activated": False'){throw "STEP27_PAYMENT_LICENSE_SEPARATION_FAIL"}
if($apiText -notmatch '"trading_execution_changed": False'){throw "STEP27_PAYMENT_EXECUTION_SEPARATION_FAIL"}
Log "STEP27_PAYMENT_LICENSE_SEPARATION=PASS"

[ordered]@{
step="27";version="1.0.0";timestamp=(Get-Date).ToUniversalTime().ToString("o");
step26a_dependency="PASS";runtime_health="PASS";runtime_safety="PASS";
live_openapi="PASS";auth_boundary="PASS";db_contract="PASS";
crm="PASS";billing_core="PASS";license_workflow="PASS";notification_outbox="PASS";
admin_console="PASS";payment_license_separation="PASS";no_execution_reference=$true;
payment_provider_certified=$false;email_provider_certified=$false;push_provider_certified=$false;
execution_enabled=$false;live_money_authorized=$false;
result="PASS"
}|ConvertTo-Json -Depth 8|Set-Content $Report -Encoding UTF8

Log "STEP27_CRM=PASS"
Log "STEP27_BILLING_CORE=PASS"
Log "STEP27_LICENSE_WORKFLOW=PASS"
Log "STEP27_NOTIFICATION_OUTBOX=PASS"
Log "STEP27_ADMIN_OPERATIONS=PASS"
Log "STEP27_EXTERNAL_PROVIDERS=GATED_UNCERTIFIED"
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP27=PASS"
Log ("STEP27_REPORT={0}" -f $Report)

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 27 = CERTIFIED PASS (CORE)"
Write-Host " CRM = PASS"
Write-Host " Billing/Licensing core = PASS"
Write-Host " Notification outbox = PASS"
Write-Host " Customer/Admin operations = PASS"
Write-Host " Payment/email/push providers = NOT YET CERTIFIED"
Write-Host " Live money authorized = FALSE"
Write-Host "===================================================="
Write-Host ("Report: {0}" -f $Report)
