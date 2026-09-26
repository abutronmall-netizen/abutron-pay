param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$PublicApi = "https://api.abutronfx.online",
    [string]$DeviceModel = "",
    [string]$AndroidVersion = "",
    [string]$BuildId = ""
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$CertDir = Join-Path $Root "certification\step26b\android"
$LogDir = "C:\Abutron\Step26B\logs"
New-Item -ItemType Directory -Force -Path $CertDir,$LogDir | Out-Null

$Log = Join-Path $LogDir "step26b_android_acceptance_$Stamp.log"
$Report = Join-Path $CertDir "STEP26B_ANDROID_ACCEPTANCE_$Stamp.json"

function Log([string]$m) {
    $line = "$(Get-Date -Format s) $m"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

function Get-HttpStatus([string]$Uri,[string]$Method="GET") {
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

function Ask-PassFail([string]$Name,[string]$Prompt) {
    while ($true) {
        Write-Host ""
        Write-Host ("TEST: {0}" -f $Prompt) -ForegroundColor Cyan
        $v = (Read-Host "Enter PASS or FAIL").Trim().ToUpperInvariant()
        if ($v -in @("PASS","FAIL")) {
            Log ("STEP26B_ANDROID_DEVICE_{0}={1}" -f $Name,$v)
            return $v
        }
        Write-Host "Please enter PASS or FAIL."
    }
}

Log "STEP26B_ANDROID_ACCEPTANCE_V1_0_0_START"

# -------- Server/runtime safety gates --------
$health = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 15
if($health.status -ne "ok") { throw "STEP26B_ANDROID_ABORT_LOCAL_HEALTH" }
if($health.execution_enabled -ne $false) { throw "STEP26B_ANDROID_ABORT_EXECUTION_ON" }
if($health.mt5.live_trading -ne $false) { throw "STEP26B_ANDROID_ABORT_LIVE_TRADING_ON" }
if($health.mt5.management_enabled -ne $false) { throw "STEP26B_ANDROID_ABORT_MANAGEMENT_ON" }
if($health.database -ne $true) { throw "STEP26B_ANDROID_ABORT_DATABASE" }

Log "STEP26B_ANDROID_LOCAL_HEALTH=PASS"
Log "STEP26B_ANDROID_EXECUTION_OFF=PASS"
Log "STEP26B_ANDROID_LIVE_TRADING_OFF=PASS"
Log "STEP26B_ANDROID_MANAGEMENT_OFF=PASS"

$healthz = Get-HttpStatus ($PublicApi.TrimEnd("/") + "/healthz")
if($healthz -ne 200) { throw "STEP26B_ANDROID_ABORT_PUBLIC_HEALTHZ=$healthz" }
Log "STEP26B_ANDROID_PUBLIC_HEALTHZ=PASS"

# Protected customer routes must reach FastAPI rather than Caddy default deny.
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
    $s = Get-HttpStatus ($PublicApi.TrimEnd("/") + $p)
    Log ("STEP26B_ANDROID_PUBLIC_ALLOWED={0}:{1}" -f $p,$s)
    if($s -notin @(401,403,422)) {
        throw ("STEP26B_ANDROID_ABORT_ALLOWED_ROUTE path={0} status={1}" -f $p,$s)
    }
}
Log "STEP26B_ANDROID_PUBLIC_CUSTOMER_ROUTES=PASS"

# Sensitive routes must remain default-denied publicly.
$blocked = @(
    @{Method="POST"; Path="/v1/evaluate"},
    @{Method="POST"; Path="/v1/live/XAUUSD"},
    @{Method="GET";  Path="/v1/positions"},
    @{Method="POST"; Path="/v1/manage"},
    @{Method="POST"; Path="/v1/close/1"},
    @{Method="GET";  Path="/v1/admin/summary"},
    @{Method="GET";  Path="/openapi.json"},
    @{Method="GET";  Path="/docs"},
    @{Method="GET";  Path="/health"}
)

foreach($x in $blocked) {
    $s = Get-HttpStatus ($PublicApi.TrimEnd("/") + $x.Path) $x.Method
    Log ("STEP26B_ANDROID_PUBLIC_BLOCKED={0}:{1}:{2}" -f $x.Method,$x.Path,$s)
    if($s -ne 404) {
        throw ("STEP26B_ANDROID_ABORT_SENSITIVE_ROUTE method={0} path={1} status={2}" -f $x.Method,$x.Path,$s)
    }
}
Log "STEP26B_ANDROID_PUBLIC_SENSITIVE_BLOCK=PASS"

# -------- Device metadata --------
if(-not $DeviceModel) { $DeviceModel = Read-Host "Android device model (example: Samsung Galaxy S24)" }
if(-not $AndroidVersion) { $AndroidVersion = Read-Host "Android version (example: 16)" }
if(-not $BuildId) { $BuildId = Read-Host "EAS build ID or short build reference (optional)" }

Write-Host ""
Write-Host "====================================================" -ForegroundColor Yellow
Write-Host " ANDROID REAL-DEVICE ACCEPTANCE" -ForegroundColor Yellow
Write-Host "====================================================" -ForegroundColor Yellow
Write-Host "Use MOBILE DATA for the first login/dashboard test."
Write-Host "Use only a TEST customer account."
Write-Host "Do not enable live trading."
Write-Host ""

# -------- Manual real-device test matrix --------
$results = [ordered]@{}
$results["install_launch"] = Ask-PassFail "INSTALL_LAUNCH" "Preview APK installs and Abutron FX launches without crash/blank screen."
$results["mobile_data_tls"] = Ask-PassFail "MOBILE_DATA_TLS" "With Wi-Fi OFF, the app connects over mobile data with no TLS/certificate/network error."
$results["register"] = Ask-PassFail "REGISTER" "New test customer registration works, including required risk/T&C acceptance if shown."
$results["login"] = Ask-PassFail "LOGIN" "Valid test credentials log in successfully; invalid credentials fail cleanly."
$results["bootstrap_dashboard"] = Ask-PassFail "BOOTSTRAP_DASHBOARD" "Dashboard/bootstrap loads authenticated customer data without 404/500 errors."
$results["accounts"] = Ask-PassFail "ACCOUNTS" "Customer accounts/status view loads successfully."
$results["trades"] = Ask-PassFail "TRADES" "Customer trades/history view loads successfully, including empty-state handling."
$results["profile"] = Ask-PassFail "PROFILE" "Profile view/update works for a safe non-sensitive field if the UI exposes it."
$results["notifications"] = Ask-PassFail "NOTIFICATIONS" "Notifications screen/preferences load and available actions work."
$results["support"] = Ask-PassFail "SUPPORT" "Support screen loads and a test support ticket can be created/read if exposed by the app."
$results["session_persistence"] = Ask-PassFail "SESSION_PERSISTENCE" "After force-closing and reopening the app, the session behaves correctly (persists or requires login according to design) without corruption."
$results["offline_safe"] = Ask-PassFail "OFFLINE_SAFE" "Airplane mode/offline state produces a safe error/loading state and does not crash."
$results["reconnect"] = Ask-PassFail "RECONNECT" "After restoring mobile data, the app recovers/reloads without reinstalling."
$results["background_resume"] = Ask-PassFail "BACKGROUND_RESUME" "Background the app for at least 60 seconds, resume it, and confirm it remains stable."
$results["no_buy_sell"] = Ask-PassFail "NO_BUY_SELL" "No usable Buy/Sell/Place Order trading control is present anywhere in the app."
$results["no_live_enable"] = Ask-PassFail "NO_LIVE_ENABLE" "No mobile control can enable live-money execution or broker management."
$results["no_secret_exposure"] = Ask-PassFail "NO_SECRET_EXPOSURE" "No broker password, cTrader secret, JWT signing secret, webhook secret, or private API key is visible in the UI/error output."

# -------- Final safety re-check --------
$health2 = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 15
$finalSafety = (
    $health2.status -eq "ok" -and
    $health2.execution_enabled -eq $false -and
    $health2.mt5.live_trading -eq $false -and
    $health2.mt5.management_enabled -eq $false -and
    $health2.database -eq $true
)

if($finalSafety) {
    Log "STEP26B_ANDROID_FINAL_SERVER_SAFETY=PASS"
} else {
    Log "STEP26B_ANDROID_FINAL_SERVER_SAFETY=FAIL"
}

$manualPass = -not ($results.Values -contains "FAIL")
$overall = if($manualPass -and $finalSafety) { "PASS" } else { "FAIL" }

$reportObject = [ordered]@{
    step = "26B"
    platform = "android"
    version = "1.0.0"
    timestamp = (Get-Date).ToUniversalTime().ToString("o")
    device = [ordered]@{
        model = $DeviceModel
        android_version = $AndroidVersion
        eas_build_id = $BuildId
    }
    server = [ordered]@{
        local_health = "PASS"
        execution_enabled = $false
        live_trading = $false
        management_enabled = $false
        public_healthz = "PASS"
        customer_route_perimeter = "PASS"
        sensitive_route_block = "PASS"
        final_safety = $(if($finalSafety){"PASS"}else{"FAIL"})
    }
    device_tests = $results
    read_only = $(if($results["no_buy_sell"] -eq "PASS" -and $results["no_live_enable"] -eq "PASS"){$true}else{$false})
    live_money_authorized = $false
    result = $overall
}

$reportObject | ConvertTo-Json -Depth 8 | Set-Content $Report -Encoding UTF8

Log ("STEP26B_ANDROID_ACCEPTANCE={0}" -f $overall)
Log "LIVE_MONEY_AUTHORIZED=False"
Log ("STEP26B_ANDROID_REPORT={0}" -f $Report)

Write-Host ""
Write-Host "===================================================="
if($overall -eq "PASS") {
    Write-Host " ABUTRON STEP 26B ANDROID ACCEPTANCE = PASS" -ForegroundColor Green
} else {
    Write-Host " ABUTRON STEP 26B ANDROID ACCEPTANCE = FAIL" -ForegroundColor Red
}
Write-Host " Live money authorized = FALSE"
Write-Host "===================================================="
Write-Host ("Report: {0}" -f $Report)
Write-Host ("Log:    {0}" -f $Log)
