param(
    [ValidateSet("BUY","SELL")]
    [string]$Direction = "BUY"
)

$ErrorActionPreference = "Stop"

# =====================================================================
# ABUTRON STEP 17
# CONTROLLED IC MARKETS DEMO EXECUTION CERTIFICATION
#
# This is the first gate that intentionally permits a broker-side DEMO
# transaction. Production .env execution remains OFF; the running Bridge
# remains live_trading=false. Actual sending is enabled only inside the
# isolated certification helper process.
#
# Requirements:
#   - IC Markets DEMO server only
#   - exact configured account login/server
#   - MT5 terminal trade permission must already be allowed
#   - worker OFF
#   - zero existing XAUUSD positions/pending orders
#   - broker minimum volume only
#   - one certification order
#   - duplicate replay must not create another deal
#   - mandatory immediate close
#   - zero residual exposure
# =====================================================================

$root       = "C:\Abutron\TradingPlatformV4"
$jarvisRoot = "C:\Abutron\Jarvis"

$envFile    = "$root\.env"
$jarvisEnv  = "$jarvisRoot\.env"
$pythonExe  = "$root\.venv\Scripts\python.exe"
$helper     = "$root\scripts\step17_controlled_demo_execution.py"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$logDir = "$root\logs"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$summaryFile = "$logDir\step17_summary_$stamp.txt"

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

function Confirm-SafetyBaseline {
    $exec = [string](Get-EnvValue $envFile "ABUTRON_EXECUTION_ENABLED")
    $live = [string](Get-EnvValue $envFile "MT5_LIVE_TRADING")
    $mgmt = [string](Get-EnvValue $envFile "MT5_MANAGEMENT_ENABLED")
    $demo = [string](Get-EnvValue $envFile "MT5_DEMO_ONLY")

    if ($exec.ToLowerInvariant() -ne "false") {
        throw "ABUTRON_EXECUTION_ENABLED must remain false."
    }

    if ($live.ToLowerInvariant() -ne "false") {
        throw "MT5_LIVE_TRADING must remain false in production .env."
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

function Invoke-ZeroExposureProbe {
    $probe = @'
import sys
import MetaTrader5 as mt5

path = sys.argv[1]
magic = int(sys.argv[2])

if not mt5.initialize(path=path):
    print("PROBE_INIT=False")
    raise SystemExit(2)

try:
    positions = mt5.positions_get()
    if positions is None:
        print("PROBE_POSITIONS_OK=False")
        raise SystemExit(3)

    owned = [
        p for p in positions
        if int(getattr(p, "magic", 0) or 0) == magic
        or str(getattr(p, "comment", "") or "").upper().startswith("ABUTRON")
    ]

    print("PROBE_INIT=True")
    print("PROBE_POSITIONS_OK=True")
    print("PROBE_ABUTRON_POSITION_COUNT=" + str(len(owned)))

    if owned:
        raise SystemExit(4)
finally:
    mt5.shutdown()
'@

    $probeOutput = @(
        $probe |
        & $pythonExe - $mt5Path 400040 2>&1
    )

    $exitCode = $LASTEXITCODE

    foreach ($line in $probeOutput) {
        Write-Host $line
    }

    return $exitCode
}

try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " ABUTRON - STEP 17"
    Write-Host " CONTROLLED IC MARKETS DEMO EXECUTION"
    Write-Host " ONE MINIMUM-VOLUME ORDER / MANDATORY CLEANUP"
    Write-Host "===================================================="
    Write-Host "CERTIFICATION_DIRECTION=$Direction"
    Write-Host "DIRECTION_IS_MARKET_RECOMMENDATION=False"

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
            throw "Required Step 17 file missing: $required"
        }
    }

    New-Item `
        -ItemType Directory `
        -Path $logDir `
        -Force |
        Out-Null

    # -----------------------------------------------------------------
    # 1. PRODUCTION SAFETY BASELINE
    # -----------------------------------------------------------------
    Confirm-SafetyBaseline

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

    $coreHealth = Get-CoreHealth
    $bridgeHealth = Get-BridgeHealth

    if ($coreHealth.status -ne "ok") {
        throw "Core unhealthy."
    }

    if ($coreHealth.kronos_loaded -ne $true) {
        throw "Kronos not loaded."
    }

    if ($coreHealth.execution_enabled -ne $false) {
        throw "Core execution unexpectedly enabled."
    }

    if ($bridgeHealth.status -ne "ok") {
        throw "Bridge unhealthy."
    }

    if ($bridgeHealth.mt5_connected -ne $true) {
        throw "Bridge is not connected to MT5."
    }

    if ($bridgeHealth.live_trading -ne $false) {
        throw "Production Bridge live trading must remain OFF."
    }

    if ($bridgeHealth.management_enabled -ne $false) {
        throw "Production Bridge management must remain OFF."
    }

    if (-not (Get-JarvisObserveOnly)) {
        throw "Jarvis is not OBSERVE_ONLY."
    }

    $mt5 = @(Get-ExpectedMT5)

    if ($mt5.Count -ne 1) {
        throw "Expected exactly one production MT5 terminal."
    }

    $mt5Pid = [int]$mt5[0].ProcessId

    Write-Host "SAFETY_BASELINE=PASS"
    Write-Host "CORE_PID=$corePid"
    Write-Host "BRIDGE_PID=$bridgePid"
    Write-Host "MT5_PID=$mt5Pid"
    Write-Host "JARVIS_PID=$jarvisPid"
    Write-Host "KRONOS_LOADED=True"
    Write-Host "JARVIS_MODE=OBSERVE_ONLY"
    Write-Host "WORKER=OFF"
    Write-Host "PRODUCTION_LIVE_TRADING=OFF"
    Write-Host "MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"

    # -----------------------------------------------------------------
    # 2. HELPER COMPILE
    # -----------------------------------------------------------------
    & $pythonExe `
        -m py_compile `
        $helper

    if ($LASTEXITCODE -ne 0) {
        throw "Step 17 helper failed Python syntax validation."
    }

    Write-Host "STEP17_PYTHON_SYNTAX=PASS"

    # -----------------------------------------------------------------
    # 3. ACTUAL CONTROLLED DEMO CERTIFICATION
    # -----------------------------------------------------------------
    Write-Host ""
    Write-Host "--- CONTROLLED DEMO EXECUTION ---"

    $previousErrorActionPreference = $ErrorActionPreference

    try {
        # Native Python writes tracebacks to stderr. Do not let PowerShell's
        # global Stop preference terminate the capture on the first stderr line.
        $ErrorActionPreference = "Continue"

        $helperOutput = @(
            & $pythonExe `
                $helper `
                --mt5-path $mt5Path `
                --symbol XAUUSD `
                --direction $Direction 2>&1
        )

        $helperExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    foreach ($line in $helperOutput) {
        Write-Host ([string]$line)
    }

    if ($helperExit -ne 0) {
        throw "Step 17 helper did not certify. Exit code=$helperExit"
    }

    $values = @{}

    foreach ($line in $helperOutput) {
        $text = [string]$line

        if ($text -match '^([A-Z0-9_]+)=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }

    $requiredPasses = @(
        "DEMO_ACCOUNT_IDENTITY",
        "ZERO_SYMBOL_POSITION_BASELINE",
        "ZERO_SYMBOL_PENDING_ORDER_BASELINE",
        "ZERO_ABUTRON_POSITION_BASELINE",
        "TEMP_IDEMPOTENCY_STORE",
        "BROKER_MINIMUM_VOLUME_ONLY",
        "ORDER_PAYLOAD_PRECHECK",
        "BROKER_ORDER_CHECK",
        "DEMO_ORDER_SEND",
        "BROKER_RETCODE_DONE",
        "DEMO_POSITION_DISCOVERED",
        "POSITION_TICKET_RECONCILIATION",
        "OPEN_DEAL_HISTORY_RECONCILIATION",
        "REAL_FILL_IDEMPOTENCY_DUPLICATE",
        "MANDATORY_DEMO_CLEANUP_CLOSE",
        "OPEN_CLOSE_HISTORY_RECONCILIATION",
        "ZERO_RESIDUAL_SYMBOL_EXPOSURE",
        "ZERO_RESIDUAL_ABUTRON_EXPOSURE",
        "REAL_EXECUTION_RESULT_PERSISTED",
        "REAL_EXECUTION_CLAIM_RELEASED",
        "PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED",
        "PROCESS_LOCAL_SETTINGS_RESTORED",
        "TEMP_CERTIFICATION_STORE_REMOVED",
        "STEP_17_HELPER",
        "REAL_DEMO_BROKER_EXECUTION",
        "REAL_DEMO_BROKER_CLOSE_CLEANUP",
        "ZERO_RESIDUAL_EXPOSURE"
    )

    foreach ($name in $requiredPasses) {
        if ($values[$name] -ne "PASS") {
            throw "Step 17 required gate missing or failed: $name"
        }
    }

    if ($values["MARKET_SIGNAL_USED"] -ne "False") {
        throw "Step 17 unexpectedly claims a market signal was used."
    }

    if ($values["AUTONOMOUS_WORKER_USED"] -ne "False") {
        throw "Step 17 unexpectedly used autonomous worker."
    }

    Write-Host "STEP17_HELPER_RESULT=PASS"

    # -----------------------------------------------------------------
    # 4. PRODUCTION PROCESS CONTINUITY
    # -----------------------------------------------------------------
    Confirm-SafetyBaseline

    if ((Get-ListenerPid 8088) -ne $corePid) {
        throw "Core PID changed during Step 17."
    }

    if ((Get-ListenerPid 8090) -ne $bridgePid) {
        throw "Production Bridge PID changed during Step 17."
    }

    if ((Get-ListenerPid 8787) -ne $jarvisPid) {
        throw "Jarvis PID changed during Step 17."
    }

    $mt5Final = @(Get-ExpectedMT5)

    if ($mt5Final.Count -ne 1) {
        throw "MT5 process count changed during Step 17."
    }

    if ([int]$mt5Final[0].ProcessId -ne $mt5Pid) {
        throw "MT5 PID changed during Step 17."
    }

    $coreFinal = Get-CoreHealth
    $bridgeFinal = Get-BridgeHealth

    if ($coreFinal.status -ne "ok" -or $coreFinal.kronos_loaded -ne $true) {
        throw "Core/Kronos unhealthy after Step 17."
    }

    if ($coreFinal.execution_enabled -ne $false) {
        throw "Core execution changed after Step 17."
    }

    if (
        $bridgeFinal.status -ne "ok" -or
        $bridgeFinal.mt5_connected -ne $true -or
        $bridgeFinal.live_trading -ne $false -or
        $bridgeFinal.management_enabled -ne $false
    ) {
        throw "Production Bridge safety state changed after Step 17."
    }

    if (-not (Get-JarvisObserveOnly)) {
        throw "Jarvis left OBSERVE_ONLY."
    }

    # Independent final zero-Abutron-exposure probe.
    $zeroProbeExit = Invoke-ZeroExposureProbe

    if ($zeroProbeExit -ne 0) {
        throw "Independent final exposure probe detected residual Abutron position."
    }

    Write-Host "INDEPENDENT_ZERO_EXPOSURE_PROBE=PASS"

    $summary = @(
        "STEP_17=PASS"
        "CERTIFICATION_DIRECTION=$Direction"
        "DIRECTION_IS_MARKET_RECOMMENDATION=False"
        "DEMO_ACCOUNT_IDENTITY=PASS"
        "BROKER_MINIMUM_VOLUME_ONLY=PASS"
        "BROKER_ORDER_CHECK=PASS"
        "REAL_DEMO_BROKER_EXECUTION=PASS"
        "BROKER_RETCODE_DONE=PASS"
        "POSITION_TICKET_RECONCILIATION=PASS"
        "OPEN_DEAL_HISTORY_RECONCILIATION=PASS"
        "REAL_FILL_IDEMPOTENCY_DUPLICATE=PASS"
        "MANDATORY_DEMO_CLEANUP_CLOSE=PASS"
        "OPEN_CLOSE_HISTORY_RECONCILIATION=PASS"
        "ZERO_RESIDUAL_EXPOSURE=PASS"
        "INDEPENDENT_ZERO_EXPOSURE_PROBE=PASS"
        "PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED=PASS"
        "CORE_PID_CONTINUITY=PASS"
        "BRIDGE_PID_CONTINUITY=PASS"
        "MT5_PID_CONTINUITY=PASS"
        "JARVIS_PID_CONTINUITY=PASS"
        "KRONOS_LOADED=True"
        "JARVIS_MODE=OBSERVE_ONLY"
        "WORKER=OFF"
        "PRODUCTION_LIVE_TRADING=OFF"
        "MANAGEMENT=OFF"
        "ABUTRON_EXECUTION=OFF"
        "MARKET_SIGNAL_USED=False"
        "AUTONOMOUS_WORKER_USED=False"
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
        Confirm-SafetyBaseline
        Write-Host "FAILSAFE_PRODUCTION_EXECUTION_LOCKS=PASS"
    }
    catch {
        Write-Host "FAILSAFE_PRODUCTION_EXECUTION_LOCKS=CHECK_REQUIRED"
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

    try {
        $finalProbeExit = Invoke-ZeroExposureProbe

        if ($finalProbeExit -eq 0) {
            Write-Host "FAILSAFE_ZERO_ABUTRON_EXPOSURE=PASS"
        }
        else {
            Write-Host "FAILSAFE_ZERO_ABUTRON_EXPOSURE=CHECK_REQUIRED"
        }
    }
    catch {
        Write-Host "FAILSAFE_ZERO_ABUTRON_EXPOSURE=CHECK_REQUIRED"
    }
}

if (-not $certified) {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 17 = NOT CERTIFIED"
    Write-Host "===================================================="
    Write-Host "FAILURE=$failureMessage"
    Write-Host "WORKER=OFF_EXPECTED"
    Write-Host "PRODUCTION_LIVE_TRADING=OFF_EXPECTED"
    Write-Host "MANAGEMENT=OFF_EXPECTED"
    Write-Host "ABUTRON_EXECUTION=OFF_EXPECTED"
    Write-Host "CHECK_DEMO_ACCOUNT_FOR_RESIDUAL_EXPOSURE_IF_FAILSAFE_NOT_PASS"
    exit 1
}

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 17 = PASS"
Write-Host "===================================================="
Write-Host "DEMO_ACCOUNT_IDENTITY=PASS"
Write-Host "BROKER_MINIMUM_VOLUME_ONLY=PASS"
Write-Host "BROKER_ORDER_CHECK=PASS"
Write-Host "REAL_DEMO_BROKER_EXECUTION=PASS"
Write-Host "BROKER_RETCODE_DONE=PASS"
Write-Host "POSITION_TICKET_RECONCILIATION=PASS"
Write-Host "OPEN_DEAL_HISTORY_RECONCILIATION=PASS"
Write-Host "REAL_FILL_IDEMPOTENCY_DUPLICATE=PASS"
Write-Host "MANDATORY_DEMO_CLEANUP_CLOSE=PASS"
Write-Host "OPEN_CLOSE_HISTORY_RECONCILIATION=PASS"
Write-Host "ZERO_RESIDUAL_EXPOSURE=PASS"
Write-Host "INDEPENDENT_ZERO_EXPOSURE_PROBE=PASS"
Write-Host "PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED=PASS"
Write-Host "CORE_PID_CONTINUITY=PASS"
Write-Host "BRIDGE_PID_CONTINUITY=PASS"
Write-Host "MT5_PID_CONTINUITY=PASS"
Write-Host "JARVIS_PID_CONTINUITY=PASS"
Write-Host "KRONOS_LOADED=True"
Write-Host "JARVIS_MODE=OBSERVE_ONLY"
Write-Host "WORKER=OFF"
Write-Host "PRODUCTION_LIVE_TRADING=OFF"
Write-Host "MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "MARKET_SIGNAL_USED=False"
Write-Host "AUTONOMOUS_WORKER_USED=False"
Write-Host "SUMMARY_FILE=$summaryFile"
Write-Host "===================================================="

exit 0
