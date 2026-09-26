param([string]$Root="C:\Abutron\TradingPlatformV4")
$ErrorActionPreference="Stop"
$Python=Join-Path $Root ".venv\Scripts\python.exe"
$Stamp=Get-Date -Format "yyyyMMdd-HHmmss"
$Dir=Join-Path $Root "certification\step26a"
New-Item -ItemType Directory -Force -Path $Dir|Out-Null
$Report=Join-Path $Dir "STEP26A_CERTIFICATION_$Stamp.json"

$health=$null
try{$health=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10}catch{}

$Verifier=Join-Path $Dir "step26a_cert_verify_$Stamp.py"
@'
from sqlalchemy import inspect
from abutron.api import app
from abutron.config import settings
from abutron.platform_db import engine

routes={(m,r.path) for r in app.routes for m in (getattr(r,"methods",set()) or set())}
required_routes={
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
required_tables={
"step26a_devices",
"step26a_notification_receipts",
"step26a_support_tickets",
"step26a_customer_preferences",
}
tables=set(inspect(engine).get_table_names())
missing_routes=sorted(required_routes-routes)
missing_tables=sorted(required_tables-tables)
assert not missing_routes, missing_routes
assert not missing_tables, missing_tables
assert settings.execution_enabled is False, "execution_enabled must remain false"
print("STEP26A_ROUTE_CONTRACT=PASS")
print("STEP26A_DB_CONTRACT=PASS")
print("STEP26A_EXECUTION_OFF=PASS")
'@|Set-Content $Verifier -Encoding UTF8

Set-Location $Root
$out=& $Python $Verifier 2>&1
$exit=$LASTEXITCODE
$out|ForEach-Object{Write-Host $_}

$mobile=Test-Path (Join-Path $Root "mobile\AbutronMobile\App.tsx")
$admin=Test-Path (Join-Path $Root "admin\step26a.html")
$source=Get-Content (Join-Path $Root "abutron\step26a_api.py") -Raw
$readOnly=($source -match '"mobile_trading_mode": "READ_ONLY"' -and $source -match '"order_entry": False')
$forbidden=Select-String -Path (Join-Path $Root "abutron\step26a_*.py") -Pattern "order_send|gateway\.order|svc\.gateway\.order|MT5Gateway|execute=True" -CaseSensitive:$false -ErrorAction SilentlyContinue
$healthOk=($null -ne $health -and $health.status -eq "ok")
$healthSafe=($null -eq $health -or $health.execution_enabled -eq $false)

$pass=($exit -eq 0 -and $mobile -and $admin -and $readOnly -and @($forbidden).Count -eq 0 -and $healthSafe)
$result=if($pass){"PASS"}else{"FAIL"}

[ordered]@{
    step="26A"
    version="1.0.0"
    timestamp=(Get-Date).ToUniversalTime().ToString("o")
    route_db_contract=($exit -eq 0)
    mobile_source_present=$mobile
    admin_console_present=$admin
    mobile_read_only=$readOnly
    forbidden_execution_reference_count=@($forbidden).Count
    api_health_ok=$healthOk
    execution_enabled=if($health){$health.execution_enabled}else{$null}
    result=$result
}|ConvertTo-Json -Depth 8|Set-Content $Report

Write-Host "STEP26A_ROUTE_DB_CONTRACT=$(if($exit -eq 0){'PASS'}else{'FAIL'})"
Write-Host "STEP26A_MOBILE_SOURCE=$(if($mobile){'PASS'}else{'FAIL'})"
Write-Host "STEP26A_ADMIN_CONSOLE=$(if($admin){'PASS'}else{'FAIL'})"
Write-Host "STEP26A_MOBILE_READ_ONLY=$(if($readOnly){'PASS'}else{'FAIL'})"
Write-Host "STEP26A_NO_EXECUTION_REFERENCE=$(if(@($forbidden).Count -eq 0){'PASS'}else{'FAIL'})"
Write-Host "STEP26A_API_HEALTH=$(if($healthOk){'PASS'}else{'FAIL'})"
Write-Host "STEP26A=$result"
Write-Host "STEP26A_REPORT=$Report"
if(-not $pass){exit 2}
