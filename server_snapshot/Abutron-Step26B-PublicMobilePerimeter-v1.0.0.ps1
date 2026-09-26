param(
    [string]$CaddyFile = "C:\caddy\Caddyfile",
    [string]$CaddyExe  = "C:\caddy\caddy.exe"
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Backup = "$CaddyFile.pre-step26b-$Stamp"
$Candidate = "$CaddyFile.step26b-candidate-$Stamp"
$Marker = "# STEP26B MOBILE CUSTOMER PUBLIC ALLOWLIST v1.0.0"

function Say([string]$s) { Write-Host $s }

function Get-Status([string]$Uri,[string]$Method="GET") {
    try {
        $r = Invoke-WebRequest -Uri $Uri -Method $Method -UseBasicParsing -TimeoutSec 20
        return [int]$r.StatusCode
    }
    catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            return [int]$_.Exception.Response.StatusCode
        }
        throw
    }
}

function Rollback([string]$Reason) {
    Say ("STEP26B_PERIMETER_ROLLBACK_REASON={0}" -f $Reason)
    if (Test-Path $Backup) {
        Copy-Item $Backup $CaddyFile -Force
        & $CaddyExe reload --config $CaddyFile --adapter caddyfile
        Say "STEP26B_PERIMETER_ROLLBACK=APPLIED"
    }
    throw $Reason
}

Say "STEP26B_PUBLIC_MOBILE_PERIMETER_V1_0_0_START"

if(-not(Test-Path $CaddyFile)){ throw "CADDYFILE_NOT_FOUND=$CaddyFile" }
if(-not(Test-Path $CaddyExe)){ throw "CADDY_EXE_NOT_FOUND=$CaddyExe" }

$svc = Get-Service caddy -ErrorAction Stop
if($svc.Status -ne "Running"){ throw "CADDY_SERVICE_NOT_RUNNING" }
Say "STEP26B_CADDY_SERVICE=PASS"

# Safety gate: the internal trading platform must remain non-live.
$health = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 15
if($health.status -ne "ok"){ throw "STEP26B_LOCAL_API_HEALTH_FAIL" }
if($health.execution_enabled -ne $false){ throw "STEP26B_ABORT_EXECUTION_ENABLED" }
if($health.mt5.live_trading -ne $false){ throw "STEP26B_ABORT_LIVE_TRADING_ENABLED" }
if($health.mt5.management_enabled -ne $false){ throw "STEP26B_ABORT_MANAGEMENT_ENABLED" }
Say "STEP26B_LOCAL_API_SAFETY=PASS"

# Safe public health endpoint already exists and intentionally exposes no backend details.
$healthzStatus = Get-Status "https://api.abutronfx.online/healthz"
if($healthzStatus -ne 200){ throw "STEP26B_PUBLIC_HEALTHZ_FAIL status=$healthzStatus" }
Say "STEP26B_PUBLIC_HEALTHZ=PASS"

$current = Get-Content $CaddyFile -Raw

if($current -match [regex]::Escape($Marker)) {
    Say "STEP26B_ALLOWLIST_ALREADY_PRESENT=True"
    Copy-Item $CaddyFile $Candidate -Force
}
else {
    $needle = "    # Default deny: future routes are private until deliberately allowlisted."
    if(-not $current.Contains($needle)) {
        throw "STEP26B_DEFAULT_DENY_MARKER_NOT_FOUND"
    }

    $allow = @'

    # STEP26B MOBILE CUSTOMER PUBLIC ALLOWLIST v1.0.0
    # Customer/mobile routes only. Trading-control, admin, docs and OpenAPI remain private.
    @step26b_customer_get {
        method GET
        path /v1/mobile/bootstrap /v1/customer/status /v1/customer/accounts /v1/customer/trades /v1/customer/operations /v1/customer/billing/invoices* /v1/customer/notification-preferences /v1/devices /v1/notifications /v1/support/tickets
    }
    handle @step26b_customer_get {
        reverse_proxy 127.0.0.1:8088
    }

    @step26b_customer_patch {
        method PATCH
        path /v1/customer/profile /v1/customer/notification-preferences
    }
    handle @step26b_customer_patch {
        reverse_proxy 127.0.0.1:8088
    }

    @step26b_customer_put {
        method PUT
        path /v1/customer/notification-preferences /v1/notifications/*
    }
    handle @step26b_customer_put {
        reverse_proxy 127.0.0.1:8088
    }

    @step26b_customer_post {
        method POST
        path /v1/devices/register /v1/support/tickets
    }
    handle @step26b_customer_post {
        reverse_proxy 127.0.0.1:8088
    }

    @step26b_customer_delete {
        method DELETE
        path /v1/devices/*
    }
    handle @step26b_customer_delete {
        reverse_proxy 127.0.0.1:8088
    }

'@

    $candidateText = $current.Replace($needle, $allow + $needle)
    Set-Content -Path $Candidate -Value $candidateText -Encoding UTF8
}

# Validate candidate before touching the active config.
& $CaddyExe validate --config $Candidate --adapter caddyfile
if($LASTEXITCODE -ne 0){ throw "STEP26B_CADDY_CANDIDATE_VALIDATE_FAIL" }
Say "STEP26B_CADDY_CANDIDATE_VALIDATE=PASS"

Copy-Item $CaddyFile $Backup -Force
Say ("STEP26B_CADDY_BACKUP=PASS:{0}" -f $Backup)

Copy-Item $Candidate $CaddyFile -Force

try {
    & $CaddyExe validate --config $CaddyFile --adapter caddyfile
    if($LASTEXITCODE -ne 0){ throw "ACTIVE_VALIDATE_FAIL" }

    & $CaddyExe reload --config $CaddyFile --adapter caddyfile
    if($LASTEXITCODE -ne 0){ throw "CADDY_RELOAD_FAIL" }

    Start-Sleep -Seconds 3
    Say "STEP26B_CADDY_RELOAD=PASS"
}
catch {
    Rollback ("STEP26B_CADDY_APPLY_FAIL:{0}" -f $_.Exception.Message)
}

# Allowed protected routes must reach FastAPI. Unauthenticated requests should be 401/403,
# not Caddy's 404 default deny.
$allowed = @(
    "/v1/mobile/bootstrap",
    "/v1/customer/status",
    "/v1/customer/accounts",
    "/v1/customer/trades",
    "/v1/customer/operations",
    "/v1/customer/billing/invoices",
    "/v1/customer/notification-preferences",
    "/v1/devices",
    "/v1/notifications",
    "/v1/support/tickets"
)
foreach($p in $allowed) {
    $s = Get-Status ("https://api.abutronfx.online" + $p)
    Say ("STEP26B_PUBLIC_ALLOWED={0}:{1}" -f $p,$s)
    if($s -notin @(401,403,422)) {
        Rollback ("STEP26B_ALLOWED_ROUTE_FAIL path={0} status={1}" -f $p,$s)
    }
}
Say "STEP26B_PUBLIC_CUSTOMER_ALLOWLIST=PASS"

# Sensitive trading/admin/introspection paths must still hit Caddy's default deny.
$blocked = @(
    @{ Method="POST"; Path="/v1/evaluate" },
    @{ Method="POST"; Path="/v1/live/XAUUSD" },
    @{ Method="GET";  Path="/v1/positions" },
    @{ Method="POST"; Path="/v1/manage" },
    @{ Method="POST"; Path="/v1/close/1" },
    @{ Method="GET";  Path="/v1/admin/summary" },
    @{ Method="GET";  Path="/openapi.json" },
    @{ Method="GET";  Path="/docs" },
    @{ Method="GET";  Path="/health" }
)
foreach($x in $blocked) {
    $s = Get-Status ("https://api.abutronfx.online" + $x.Path) $x.Method
    Say ("STEP26B_PUBLIC_BLOCKED={0}:{1}:{2}" -f $x.Method,$x.Path,$s)
    if($s -ne 404) {
        Rollback ("STEP26B_BLOCKED_ROUTE_EXPOSED method={0} path={1} status={2}" -f $x.Method,$x.Path,$s)
    }
}
Say "STEP26B_TRADING_ADMIN_INTROSPECTION_BLOCK=PASS"

# Final local safety re-check.
$health2 = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 15
if($health2.status -ne "ok" -or
   $health2.execution_enabled -ne $false -or
   $health2.mt5.live_trading -ne $false -or
   $health2.mt5.management_enabled -ne $false) {
    Rollback "STEP26B_FINAL_LOCAL_SAFETY_FAIL"
}

Say "STEP26B_FINAL_LOCAL_SAFETY=PASS"
Say "LIVE_MONEY_AUTHORIZED=False"
Say "STEP26B_PUBLIC_MOBILE_PERIMETER=PASS"
Say ("STEP26B_CADDY_BACKUP={0}" -f $Backup)
