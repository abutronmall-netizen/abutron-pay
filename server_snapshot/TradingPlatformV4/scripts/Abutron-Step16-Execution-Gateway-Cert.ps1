$ErrorActionPreference = "Stop"

# =====================================================================
# ABUTRON STEP 16
# EXECUTION GATEWAY / IDEMPOTENCY / ORDER-PAYLOAD / REFUSAL CERTIFICATION
#
# Safety model:
#   - production .env execution flags remain OFF
#   - production Bridge remains running with MT5_LIVE_TRADING=false
#   - worker remains OFF
#   - certification imports the real gateway code in a separate Python process
#   - certification uses a temporary SQLite idempotency store
#   - native MT5 order_send is replaced by an in-process hard tripwire
#   - no HTTP mutating endpoint is called
#   - no broker order is sent
# =====================================================================

$root       = "C:\Abutron\TradingPlatformV4"
$jarvisRoot = "C:\Abutron\Jarvis"

$envFile    = "$root\.env"
$jarvisEnv  = "$jarvisRoot\.env"
$pythonExe  = "$root\.venv\Scripts\python.exe"
$helper     = "$root\scripts\step16_gateway_cert.py"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$logDir = "$root\logs"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$summaryFile = "$logDir\step16_summary_$stamp.txt"

$certified = $false
$failureMessage = ""

function Get-EnvValue {
    param(
        [string]$File,
        [string]$Name
    )

    $escaped = [regex]::Escape($Name)

    $line = Get-Content $File |
        Where-Object {
            $_ -match "^\s*$escaped\s*="
        } |
        Select-Object -First 1

    if (-not $line) {
        return $null
    }

    return (($line -split "=",2)[1]).Trim().Trim('"').Trim("'")
}

function Get-ListenerPid {
    param([int]$Port)

    $item = Get-NetTCPConnection `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $item) {
        return $null
    }

    return [int]$item.OwningProcess
}

function Get-ExpectedMT5 {
    return @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -ieq "terminal64.exe" -and
            $_.ExecutablePath -ieq $mt5Path
        }
    )
}

function Get-WorkerProcesses {
    return @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -match "(?i)(-m\s+abutron\.worker|abutron\\worker\.py)"
        }
    )
}

function Confirm-Safety {
    $exec = [string](Get-EnvValue $envFile "ABUTRON_EXECUTION_ENABLED")
    $live = [string](Get-EnvValue $envFile "MT5_LIVE_TRADING")
    $mgmt = [string](Get-EnvValue $envFile "MT5_MANAGEMENT_ENABLED")
    $demo = [string](Get-EnvValue $envFile "MT5_DEMO_ONLY")

    if ($exec.ToLowerInvariant() -ne "false") {
        throw "ABUTRON_EXECUTION_ENABLED must remain false."
    }

    if ($live.ToLowerInvariant() -ne "false") {
        throw "MT5_LIVE_TRADING must remain false."
    }

    if ($mgmt.ToLowerInvariant() -ne "false") {
        throw "MT5_MANAGEMENT_ENABLED must remain false."
    }

    if ($demo.ToLowerInvariant() -ne "true") {
        throw "MT5_DEMO_ONLY must remain true."
    }

    $workers = @(Get-WorkerProcesses)

    if ($workers.Count -ne 0) {
        $ids = ($workers | ForEach-Object { $_.ProcessId }) -join ","
        throw "Trading worker must remain OFF. Worker PIDs: $ids"
    }
}

function Get-CoreHealth {
    return Invoke-RestMethod `
        -Uri "http://127.0.0.1:8088/health" `
        -TimeoutSec 30
}

function Get-BridgeHealth {
    return Invoke-RestMethod `
        -Uri "http://127.0.0.1:8090/health" `
        -TimeoutSec 30
}

function Get-JarvisObserveOnly {
    $token = Get-EnvValue $jarvisEnv "JARVIS_API_TOKEN"

    if ([string]::IsNullOrWhiteSpace($token)) {
        throw "Jarvis API token unavailable."
    }

    $headers = @{
        "X-Jarvis-Token" = $token
    }

    $h = Invoke-RestMethod `
        -Uri "http://127.0.0.1:8787/v1/system/health" `
        -Headers $headers `
        -TimeoutSec 60

    $json = $h |
        ConvertTo-Json `
            -Depth 15 `
            -Compress

    return (
        ($json -match '(?i)"mode"\s*:\s*"OBSERVE_ONLY"') -or
        ($json -match '(?i)"observe_only"\s*:\s*true')
    )
}

function Get-OwnerInfo {
    param([int]$PidValue)

    $proc = Get-CimInstance `
        Win32_Process `
        -Filter "ProcessId=$PidValue" `
        -ErrorAction Stop

    $owner = Invoke-CimMethod `
        -InputObject $proc `
        -MethodName GetOwner `
        -ErrorAction Stop

    return @{
        Process = $proc
        User = $owner.User
        Domain = $owner.Domain
        Owner = "$($owner.Domain)\$($owner.User)"
    }
}

try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " ABUTRON - STEP 16"
    Write-Host " EXECUTION GATEWAY / IDEMPOTENCY"
    Write-Host " ORDER-PAYLOAD / REFUSAL CERTIFICATION"
    Write-Host " NO BROKER SEND"
    Write-Host "===================================================="

    foreach ($required in @(
        $envFile,
        $jarvisEnv,
        $pythonExe,
        $helper,
        "$root\mt5_bridge\app.py",
        "$root\mt5_bridge\store.py",
        "$root\mt5_bridge\settings.py",
        "$root\abutron\models.py",
        $mt5Path
    )) {
        if (-not (Test-Path $required)) {
            throw "Required Step 16 file missing: $required"
        }
    }

    New-Item `
        -ItemType Directory `
        -Path $logDir `
        -Force |
        Out-Null

    # -----------------------------------------------------------------
    # 1. HARD SAFETY BASELINE
    # -----------------------------------------------------------------
    Confirm-Safety

    $corePid = Get-ListenerPid 8088
    $bridgePid = Get-ListenerPid 8090
    $jarvisPid = Get-ListenerPid 8787

    if (-not $corePid) {
        throw "Core listener missing."
    }

    if (-not $bridgePid) {
        throw "Bridge listener missing."
    }

    if (-not $jarvisPid) {
        throw "Jarvis listener missing."
    }

    $coreOwner = Get-OwnerInfo $corePid
    $bridgeOwner = Get-OwnerInfo $bridgePid

    if ($coreOwner.User -ine "SYSTEM") {
        throw "Core is not SYSTEM-owned."
    }

    if ($bridgeOwner.User -ine "Administrator") {
        throw "Bridge is not Administrator-owned."
    }

    $coreHealth = Get-CoreHealth
    $bridgeHealth = Get-BridgeHealth

    if ($coreHealth.status -ne "ok") {
        throw "Core baseline unhealthy."
    }

    if ($coreHealth.kronos_loaded -ne $true) {
        throw "Kronos baseline not loaded."
    }

    if ($coreHealth.execution_enabled -ne $false) {
        throw "Core baseline execution is enabled."
    }

    if ($bridgeHealth.status -ne "ok") {
        throw "Bridge baseline unhealthy."
    }

    if ($bridgeHealth.mt5_connected -ne $true) {
        throw "Bridge baseline MT5 disconnected."
    }

    if ($bridgeHealth.live_trading -ne $false) {
        throw "Bridge baseline live trading enabled."
    }

    if ($bridgeHealth.management_enabled -ne $false) {
        throw "Bridge baseline management enabled."
    }

    if (-not (Get-JarvisObserveOnly)) {
        throw "Jarvis is not OBSERVE_ONLY."
    }

    $mt5 = @(Get-ExpectedMT5)

    if ($mt5.Count -ne 1) {
        throw "Expected exactly one production MT5 terminal."
    }

    $mt5Pid = [int]$mt5[0].ProcessId
    $mt5Session = [int]$mt5[0].SessionId

    if ([int]$bridgeOwner.Process.SessionId -ne $mt5Session) {
        throw "Bridge and MT5 Windows session mismatch."
    }

    Write-Host "SAFETY_BASELINE=PASS"
    Write-Host "CORE_PID=$corePid"
    Write-Host "BRIDGE_PID=$bridgePid"
    Write-Host "MT5_PID=$mt5Pid"
    Write-Host "JARVIS_PID=$jarvisPid"
    Write-Host "KRONOS_LOADED=True"
    Write-Host "JARVIS_MODE=OBSERVE_ONLY"
    Write-Host "WORKER=OFF"
    Write-Host "LIVE_TRADING=OFF"
    Write-Host "MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"

    # -----------------------------------------------------------------
    # 2. HELPER SYNTAX
    # -----------------------------------------------------------------
    & $pythonExe `
        -m py_compile `
        $helper

    if ($LASTEXITCODE -ne 0) {
        throw "Step 16 Python helper syntax failed."
    }

    Write-Host "STEP16_PYTHON_SYNTAX=PASS"

    # -----------------------------------------------------------------
    # 3. RUN REAL GATEWAY CERTIFICATION IN ISOLATED PROCESS
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "--- STEP 16 GATEWAY CERTIFICATION ---"

    $helperOutput = @(
        & $pythonExe `
            $helper `
            --mt5-path $mt5Path `
            --symbol XAUUSD 2>&1
    )

    $helperExit = $LASTEXITCODE

    foreach ($line in $helperOutput) {
        Write-Host $line
    }

    if ($helperExit -ne 0) {
        throw "Step 16 gateway helper failed with exit code $helperExit."
    }

    $values = @{}

    foreach ($line in $helperOutput) {
        $text = [string]$line

        if ($text -match '^([A-Z0-9_]+)=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }

    $requiredPasses = @(
        "STATIC_EXECUTION_GATEWAY_AUDIT",
        "AUTH_REFUSAL",
        "REAL_DEMO_ACCOUNT_GUARD",
        "DEMO_ACCOUNT_GUARD",
        "EXPECTED_LOGIN_GUARD",
        "EXPECTED_SERVER_GUARD",
        "ORDERPLAN_SCHEMA_REFUSAL",
        "ORDER_REQUEST_PAYLOAD",
        "BROKER_MIN_VOLUME_REFUSAL",
        "BROKER_ORDER_CHECK_NO_SEND",
        "DRY_RUN_REFUSAL",
        "IDEMPOTENCY_COMPLETED_DUPLICATE",
        "IDEMPOTENCY_IN_PROGRESS",
        "ORDER_CHECK_REJECTION_NO_SEND",
        "ORDER_CHECK_REJECTION_PERSISTED",
        "REJECTED_REQUEST_DUPLICATE_SUPPRESSED",
        "ORDER_SEND_BOUNDARY_TRIPWIRE",
        "UNRESOLVED_SEND_CLAIM_FAIL_CLOSED",
        "MANAGE_REFUSAL",
        "CLOSE_REFUSAL",
        "PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED",
        "PROCESS_LOCAL_SETTINGS_RESTORED",
        "MT5_POSITIONS_UNCHANGED",
        "ABUTRON_MAGIC_POSITIONS_UNCHANGED",
        "NO_ABUTRON_MAGIC_DEALS",
        "STEP_16_HELPER",
        "REAL_GATEWAY_ORDER_FUNCTION_EXERCISED"
    )

    foreach ($name in $requiredPasses) {
        if ($values[$name] -ne "PASS") {
            throw "Step 16 required gate missing or failed: $name"
        }
    }

    if ($values["NATIVE_ORDER_SEND_CALLS"] -ne "0") {
        throw "Native order_send call count is not zero."
    }

    if ($values["HTTP_ORDER_ENDPOINT_CALLED"] -ne "False") {
        throw "HTTP /v1/order endpoint was unexpectedly called."
    }

    if ($values["HTTP_MANAGE_ENDPOINT_CALLED"] -ne "False") {
        throw "HTTP /v1/manage endpoint was unexpectedly called."
    }

    if ($values["HTTP_CLOSE_ENDPOINT_CALLED"] -ne "False") {
        throw "HTTP /v1/close endpoint was unexpectedly called."
    }

    if ($values["BROKER_ORDER_SEND_CALLED"] -ne "False") {
        throw "Broker order_send was unexpectedly called."
    }

    Write-Host "STEP16_GATEWAY_HELPER_RESULT=PASS"

    # -----------------------------------------------------------------
    # 4. FINAL PRODUCTION CONTINUITY
    # -----------------------------------------------------------------
    Confirm-Safety

    if ((Get-ListenerPid 8088) -ne $corePid) {
        throw "Core PID changed during Step 16."
    }

    if ((Get-ListenerPid 8090) -ne $bridgePid) {
        throw "Bridge PID changed during Step 16."
    }

    if ((Get-ListenerPid 8787) -ne $jarvisPid) {
        throw "Jarvis PID changed during Step 16."
    }

    $mt5Final = @(Get-ExpectedMT5)

    if ($mt5Final.Count -ne 1) {
        throw "MT5 process count changed during Step 16."
    }

    if ([int]$mt5Final[0].ProcessId -ne $mt5Pid) {
        throw "MT5 PID changed during Step 16."
    }

    $coreFinal = Get-CoreHealth
    $bridgeFinal = Get-BridgeHealth

    if ($coreFinal.status -ne "ok") {
        throw "Core unhealthy after Step 16."
    }

    if ($coreFinal.kronos_loaded -ne $true) {
        throw "Kronos unloaded during Step 16."
    }

    if ($coreFinal.execution_enabled -ne $false) {
        throw "Core execution changed during Step 16."
    }

    if ($bridgeFinal.status -ne "ok") {
        throw "Bridge unhealthy after Step 16."
    }

    if ($bridgeFinal.mt5_connected -ne $true) {
        throw "Bridge lost MT5 during Step 16."
    }

    if ($bridgeFinal.live_trading -ne $false) {
        throw "Bridge live trading changed during Step 16."
    }

    if ($bridgeFinal.management_enabled -ne $false) {
        throw "Bridge management changed during Step 16."
    }

    if (-not (Get-JarvisObserveOnly)) {
        throw "Jarvis left OBSERVE_ONLY."
    }

    Confirm-Safety

    $summary = @(
        "STEP_16=PASS"
        "STATIC_EXECUTION_GATEWAY_AUDIT=PASS"
        "AUTH_REFUSAL=PASS"
        "DEMO_ACCOUNT_GUARD=PASS"
        "EXPECTED_LOGIN_GUARD=PASS"
        "EXPECTED_SERVER_GUARD=PASS"
        "ORDERPLAN_SCHEMA_REFUSAL=PASS"
        "ORDER_REQUEST_PAYLOAD=PASS"
        "BROKER_MIN_VOLUME_REFUSAL=PASS"
        "BROKER_ORDER_CHECK_NO_SEND=PASS"
        "DRY_RUN_REFUSAL=PASS"
        "IDEMPOTENCY_COMPLETED_DUPLICATE=PASS"
        "IDEMPOTENCY_IN_PROGRESS=PASS"
        "ORDER_CHECK_REJECTION_NO_SEND=PASS"
        "ORDER_SEND_BOUNDARY_TRIPWIRE=PASS"
        "UNRESOLVED_SEND_CLAIM_FAIL_CLOSED=PASS"
        "MANAGE_REFUSAL=PASS"
        "CLOSE_REFUSAL=PASS"
        "PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED=PASS"
        "MT5_POSITIONS_UNCHANGED=PASS"
        "NO_ABUTRON_MAGIC_DEALS=PASS"
        "NATIVE_ORDER_SEND_CALLS=0"
        "CORE_PID_CONTINUITY=PASS"
        "BRIDGE_PID_CONTINUITY=PASS"
        "MT5_PID_CONTINUITY=PASS"
        "JARVIS_PID_CONTINUITY=PASS"
        "KRONOS_LOADED=True"
        "JARVIS_MODE=OBSERVE_ONLY"
        "WORKER=OFF"
        "LIVE_TRADING=OFF"
        "MANAGEMENT=OFF"
        "ABUTRON_EXECUTION=OFF"
        "NO_TRADES_SENT"
    )

    $summary |
        Set-Content `
            -Path $summaryFile `
            -Encoding UTF8 `
            -Force

    $certified = $true
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    try {
        Confirm-Safety
        Write-Host "FAILSAFE_EXECUTION_LOCKS=PASS"
    }
    catch {
        Write-Host "FAILSAFE_EXECUTION_LOCKS=CHECK_REQUIRED"
    }

    try {
        if (@(Get-WorkerProcesses).Count -eq 0) {
            Write-Host "FAILSAFE_WORKER_OFF=PASS"
        }
        else {
            Write-Host "FAILSAFE_WORKER_OFF=FAILED"
        }
    }
    catch {
        Write-Host "FAILSAFE_WORKER_OFF=CHECK_REQUIRED"
    }
}

if (-not $certified) {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 16 = NOT CERTIFIED"
    Write-Host "===================================================="
    Write-Host "FAILURE=$failureMessage"
    Write-Host "WORKER=OFF_EXPECTED"
    Write-Host "LIVE_TRADING=OFF_EXPECTED"
    Write-Host "MANAGEMENT=OFF_EXPECTED"
    Write-Host "ABUTRON_EXECUTION=OFF_EXPECTED"
    Write-Host "NO_TRADES_SENT_EXPECTED"
    exit 1
}

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 16 = PASS"
Write-Host "===================================================="
Write-Host "STATIC_EXECUTION_GATEWAY_AUDIT=PASS"
Write-Host "AUTH_REFUSAL=PASS"
Write-Host "DEMO_ACCOUNT_GUARD=PASS"
Write-Host "EXPECTED_LOGIN_GUARD=PASS"
Write-Host "EXPECTED_SERVER_GUARD=PASS"
Write-Host "ORDERPLAN_SCHEMA_REFUSAL=PASS"
Write-Host "ORDER_REQUEST_PAYLOAD=PASS"
Write-Host "BROKER_MIN_VOLUME_REFUSAL=PASS"
Write-Host "BROKER_ORDER_CHECK_NO_SEND=PASS"
Write-Host "DRY_RUN_REFUSAL=PASS"
Write-Host "IDEMPOTENCY_COMPLETED_DUPLICATE=PASS"
Write-Host "IDEMPOTENCY_IN_PROGRESS=PASS"
Write-Host "ORDER_CHECK_REJECTION_NO_SEND=PASS"
Write-Host "ORDER_CHECK_REJECTION_PERSISTED=PASS"
Write-Host "REJECTED_REQUEST_DUPLICATE_SUPPRESSED=PASS"
Write-Host "ORDER_SEND_BOUNDARY_TRIPWIRE=PASS"
Write-Host "UNRESOLVED_SEND_CLAIM_FAIL_CLOSED=PASS"
Write-Host "MANAGE_REFUSAL=PASS"
Write-Host "CLOSE_REFUSAL=PASS"
Write-Host "PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED=PASS"
Write-Host "MT5_POSITIONS_UNCHANGED=PASS"
Write-Host "NO_ABUTRON_MAGIC_DEALS=PASS"
Write-Host "NATIVE_ORDER_SEND_CALLS=0"
Write-Host "CORE_PID_CONTINUITY=PASS"
Write-Host "BRIDGE_PID_CONTINUITY=PASS"
Write-Host "MT5_PID_CONTINUITY=PASS"
Write-Host "JARVIS_PID_CONTINUITY=PASS"
Write-Host "KRONOS_LOADED=True"
Write-Host "JARVIS_MODE=OBSERVE_ONLY"
Write-Host "WORKER=OFF"
Write-Host "LIVE_TRADING=OFF"
Write-Host "MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "HTTP_ORDER_ENDPOINT_CALLED=False"
Write-Host "HTTP_MANAGE_ENDPOINT_CALLED=False"
Write-Host "HTTP_CLOSE_ENDPOINT_CALLED=False"
Write-Host "BROKER_ORDER_SEND_CALLED=False"
Write-Host "NO_TRADES_SENT"
Write-Host "SUMMARY_FILE=$summaryFile"
Write-Host "===================================================="

exit 0
