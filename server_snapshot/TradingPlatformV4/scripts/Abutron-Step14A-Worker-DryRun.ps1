$ErrorActionPreference = "Stop"

# =====================================================================
# ABUTRON STEP 14A
# ISOLATED PRODUCTION-WORKER DRY-RUN CERTIFICATION
#
# Purpose:
#   Run the REAL production abutron.worker for a bounded observation
#   window while execution is hard-disabled at multiple independent
#   layers. Prove that the live decision loop runs and that no Abutron
#   order/deal is created.
#
# This script DOES NOT:
#   - enable ABUTRON_EXECUTION_ENABLED
#   - enable MT5_LIVE_TRADING
#   - enable MT5_MANAGEMENT_ENABLED
#   - create/enable a persistent worker task
#   - call an order/close/manage endpoint
#   - change the production .env
# =====================================================================

$root       = "C:\Abutron\TradingPlatformV4"
$jarvisRoot = "C:\Abutron\Jarvis"
$envFile    = "$root\.env"
$jarvisEnv  = "$jarvisRoot\.env"
$pythonExe  = "$root\.venv\Scripts\python.exe"

$workerFile  = "$root\abutron\worker.py"
$serviceFile = "$root\abutron\service.py"
$bridgeFile  = "$root\mt5_bridge\app.py"

$logDir    = "$root\logs"
$stdoutLog = "$logDir\step14a_worker_stdout.log"
$stderrLog = "$logDir\step14a_worker_stderr.log"
$probeFile = "$root\scripts\step14a_mt5_probe.py"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$symbol = "XAUUSD"
$magic  = 400040

$minimumObservationSeconds = 45
$minimumActivityEvents     = 3
$maximumObservationSeconds = 180

$certified = $false
$workerPid = $null
$failureMessage = ""
$testStartUnix = $null

function Get-EnvValue {
    param([string]$File,[string]$Name)

    $escaped = [regex]::Escape($Name)
    $line = Get-Content $File |
        Where-Object { $_ -match "^\s*$escaped\s*=" } |
        Select-Object -First 1

    if (-not $line) {
        return $null
    }

    return (($line -split "=",2)[1]).Trim().Trim('"').Trim("'")
}

function Get-ListenerPid {
    param([int]$Port)

    $x = Get-NetTCPConnection `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $x) {
        return $null
    }

    return [int]$x.OwningProcess
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

function Get-OwnerInfo {
    param([int]$PidValue)

    $p = Get-CimInstance `
        Win32_Process `
        -Filter "ProcessId=$PidValue" `
        -ErrorAction Stop

    $o = Invoke-CimMethod `
        -InputObject $p `
        -MethodName GetOwner `
        -ErrorAction Stop

    return @{
        Process = $p
        User    = $o.User
        Domain  = $o.Domain
        Owner   = "$($o.Domain)\$($o.User)"
    }
}

function Confirm-WorkerOff {
    $workers = @(Get-WorkerProcesses)

    if ($workers.Count -ne 0) {
        throw "A production worker is already running. Refusing isolated certification."
    }
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
}

function Get-BridgeHealth {
    return Invoke-RestMethod `
        -Uri "http://127.0.0.1:8090/health" `
        -TimeoutSec 30
}

function Get-CoreHealth {
    return Invoke-RestMethod `
        -Uri "http://127.0.0.1:8088/health" `
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

    $json = $h | ConvertTo-Json -Depth 15 -Compress

    return (
        ($json -match '(?i)"mode"\s*:\s*"OBSERVE_ONLY"') -or
        ($json -match '(?i)"observe_only"\s*:\s*true')
    )
}

function Read-WorkerLogs {
    $lines = @()

    if (Test-Path $stdoutLog) {
        $lines += @(Get-Content $stdoutLog -ErrorAction SilentlyContinue)
    }

    if (Test-Path $stderrLog) {
        $lines += @(Get-Content $stderrLog -ErrorAction SilentlyContinue)
    }

    return $lines
}

function Stop-CertWorker {
    if ($workerPid) {
        $p = Get-Process -Id $workerPid -ErrorAction SilentlyContinue

        if ($p) {
            Stop-Process -Id $workerPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }
}

function Write-ProbeFile {
    $probeLines = @(
        'import sys'
        'from datetime import datetime, timezone'
        'import MetaTrader5 as mt5'
        ''
        'path = sys.argv[1]'
        'expected_server = sys.argv[2]'
        'start_epoch = int(sys.argv[3])'
        'magic = int(sys.argv[4])'
        ''
        'ok = mt5.initialize(path=path)'
        'print("PROBE_INIT=" + str(bool(ok)))'
        'if not ok:'
        '    print("PROBE_ERROR=" + str(mt5.last_error()))'
        '    raise SystemExit(2)'
        ''
        'try:'
        '    ti = mt5.terminal_info()'
        '    ai = mt5.account_info()'
        '    connected = bool(ti and ti.connected and ai)'
        '    server_match = bool(ai and ai.server == expected_server)'
        '    trade_allowed = bool(ti.trade_allowed) if ti is not None else False'
        '    print("PROBE_CONNECTED=" + str(connected))'
        '    print("PROBE_SERVER_MATCH=" + str(server_match))'
        '    print("PROBE_TERMINAL_TRADE_ALLOWED=" + str(trade_allowed))'
        ''
        '    now = datetime.now(timezone.utc)'
        '    start_dt = datetime.fromtimestamp(start_epoch, tz=timezone.utc)'
        '    deals = mt5.history_deals_get(start_dt, now)'
        '    print("PROBE_HISTORY_OK=" + str(deals is not None))'
        '    if deals is None:'
        '        print("ABUTRON_MAGIC_DEALS=-1")'
        '    else:'
        '        count = sum(1 for d in deals if getattr(d, "magic", None) == magic)'
        '        print("ABUTRON_MAGIC_DEALS=" + str(count))'
        ''
        '    positions = mt5.positions_get()'
        '    print("PROBE_POSITIONS_OK=" + str(positions is not None))'
        '    if positions is None:'
        '        print("ABUTRON_MAGIC_POSITIONS=-1")'
        '    else:'
        '        pcount = sum(1 for p in positions if getattr(p, "magic", None) == magic)'
        '        print("ABUTRON_MAGIC_POSITIONS=" + str(pcount))'
        'finally:'
        '    mt5.shutdown()'
    )

    $probeLines |
        Set-Content `
            -Path $probeFile `
            -Encoding UTF8 `
            -Force
}

function Run-MT5Probe {
    param([long]$StartEpoch)

    $expectedServer = Get-EnvValue $envFile "MT5_EXPECTED_SERVER"

    if ([string]::IsNullOrWhiteSpace($expectedServer)) {
        throw "MT5_EXPECTED_SERVER missing."
    }

    $probeOutput = @(
        & $pythonExe `
            $probeFile `
            $mt5Path `
            $expectedServer `
            $StartEpoch `
            $magic 2>&1
    )

    $probeExit = $LASTEXITCODE

    foreach ($line in $probeOutput) {
        Write-Host $line
    }

    if ($probeExit -ne 0) {
        throw "MT5 read-only probe failed with exit code $probeExit."
    }

    $values = @{}

    foreach ($line in $probeOutput) {
        $text = [string]$line

        if ($text -match '^([A-Z0-9_]+)=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }

    return $values
}

try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " ABUTRON - STEP 14A"
    Write-Host " ISOLATED PRODUCTION-WORKER DRY-RUN CERTIFICATION"
    Write-Host " REAL WORKER / EXECUTION HARD-DISABLED"
    Write-Host "===================================================="

    New-Item `
        -ItemType Directory `
        -Path $logDir `
        -Force |
        Out-Null

    # ---------------------------------------------------------
    # 1. REQUIRED SOURCE + STATIC EXECUTION-GUARD AUDIT
    # ---------------------------------------------------------

    foreach ($required in @(
        $pythonExe,
        $envFile,
        $workerFile,
        $serviceFile,
        $bridgeFile,
        $mt5Path
    )) {
        if (-not (Test-Path $required)) {
            throw "Required production file missing: $required"
        }
    }

    $workerSource  = Get-Content $workerFile -Raw
    $serviceSource = Get-Content $serviceFile -Raw
    $bridgeSource  = Get-Content $bridgeFile -Raw

    if ($workerSource -notmatch 'evaluate_live\s*\(') {
        throw "Worker no longer calls evaluate_live."
    }

    if ($workerSource -notmatch 'execute\s*=\s*True') {
        throw "Worker execution intent changed; review required."
    }

    if ($serviceSource -notmatch 'if\s+execute\s+and\s+settings\.execution_enabled\s+and\s+result\.plan') {
        throw "TradingService execution guard changed."
    }

    if ($serviceSource -notmatch 'gateway\.order\s*\(') {
        throw "TradingService order call not found."
    }

    if ($bridgeSource -notmatch 'MT5_LIVE_TRADING_FALSE') {
        throw "MT5 Bridge dry-run guard marker not found."
    }

    Write-Host "STATIC_WORKER_PATH_AUDIT=PASS"
    Write-Host "WORKER_CALLS_EVALUATE_LIVE=PASS"
    Write-Host "WORKER_EXECUTE_TRUE_CONFIRMED=PASS"
    Write-Host "SERVICE_EXECUTION_GUARD=PASS"
    Write-Host "BRIDGE_LIVE_TRADING_GUARD=PASS"

    # ---------------------------------------------------------
    # 2. HARD SAFETY BASELINE
    # ---------------------------------------------------------

    Confirm-Safety
    Confirm-WorkerOff

    $corePid   = Get-ListenerPid 8088
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
        throw "Core unhealthy."
    }

    if ($coreHealth.kronos_loaded -ne $true) {
        throw "Kronos not loaded."
    }

    if ($coreHealth.execution_enabled -ne $false) {
        throw "Core reports execution enabled."
    }

    if ($bridgeHealth.status -ne "ok") {
        throw "Bridge unhealthy."
    }

    if ($bridgeHealth.mt5_connected -ne $true) {
        throw "MT5 disconnected."
    }

    if ($bridgeHealth.live_trading -ne $false) {
        throw "Bridge live trading is enabled."
    }

    if ($bridgeHealth.management_enabled -ne $false) {
        throw "Bridge management is enabled."
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
    $mt5Owner = Get-OwnerInfo $mt5Pid

    if ($mt5Owner.User -ine "Administrator") {
        throw "MT5 is not Administrator-owned."
    }

    if ([int]$bridgeOwner.Process.SessionId -ne $mt5Session) {
        throw "Bridge and MT5 session mismatch."
    }

    Write-Host "SAFETY_BASELINE=PASS"
    Write-Host "CORE_PID=$corePid"
    Write-Host "BRIDGE_PID=$bridgePid"
    Write-Host "JARVIS_PID=$jarvisPid"
    Write-Host "MT5_PID=$mt5Pid"
    Write-Host "KRONOS_LOADED=True"
    Write-Host "JARVIS_MODE=OBSERVE_ONLY"
    Write-Host "ABUTRON_EXECUTION=OFF"
    Write-Host "LIVE_TRADING=OFF"
    Write-Host "MANAGEMENT=OFF"
    Write-Host "WORKER_BASELINE=OFF"

    # ---------------------------------------------------------
    # 3. PRE-WORKER READ-ONLY MT5 SNAPSHOT
    # ---------------------------------------------------------

    Write-ProbeFile
    $testStartUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $baselineProbe = Run-MT5Probe -StartEpoch $testStartUnix

    if ($baselineProbe["PROBE_INIT"] -ne "True") {
        throw "Baseline MT5 probe initialization failed."
    }

    if ($baselineProbe["PROBE_CONNECTED"] -ne "True") {
        throw "Baseline MT5 probe not connected."
    }

    if ($baselineProbe["PROBE_SERVER_MATCH"] -ne "True") {
        throw "Baseline MT5 server mismatch."
    }

    if ($baselineProbe["PROBE_HISTORY_OK"] -ne "True") {
        throw "Baseline deal history unavailable."
    }

    if ($baselineProbe["PROBE_POSITIONS_OK"] -ne "True") {
        throw "Baseline positions unavailable."
    }

    $baselineMagicPositions = [int]$baselineProbe["ABUTRON_MAGIC_POSITIONS"]

    Write-Host "MT5_READ_ONLY_BASELINE=PASS"
    Write-Host "BASELINE_ABUTRON_MAGIC_POSITIONS=$baselineMagicPositions"

    # ---------------------------------------------------------
    # 4. START REAL PRODUCTION WORKER WITH CHILD ENV LOCKS
    # ---------------------------------------------------------

    Remove-Item $stdoutLog -Force -ErrorAction SilentlyContinue
    Remove-Item $stderrLog -Force -ErrorAction SilentlyContinue

    $envBackup = @{
        "ABUTRON_EXECUTION_ENABLED" = [Environment]::GetEnvironmentVariable("ABUTRON_EXECUTION_ENABLED","Process")
        "MT5_LIVE_TRADING"          = [Environment]::GetEnvironmentVariable("MT5_LIVE_TRADING","Process")
        "MT5_MANAGEMENT_ENABLED"    = [Environment]::GetEnvironmentVariable("MT5_MANAGEMENT_ENABLED","Process")
        "MT5_DEMO_ONLY"             = [Environment]::GetEnvironmentVariable("MT5_DEMO_ONLY","Process")
    }

    try {
        [Environment]::SetEnvironmentVariable("ABUTRON_EXECUTION_ENABLED","false","Process")
        [Environment]::SetEnvironmentVariable("MT5_LIVE_TRADING","false","Process")
        [Environment]::SetEnvironmentVariable("MT5_MANAGEMENT_ENABLED","false","Process")
        [Environment]::SetEnvironmentVariable("MT5_DEMO_ONLY","true","Process")

        $workerProcess = Start-Process `
            -FilePath $pythonExe `
            -ArgumentList @("-m","abutron.worker") `
            -WorkingDirectory $root `
            -RedirectStandardOutput $stdoutLog `
            -RedirectStandardError $stderrLog `
            -PassThru

        $workerPid = [int]$workerProcess.Id
    }
    finally {
        foreach ($name in $envBackup.Keys) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $envBackup[$name],
                "Process"
            )
        }
    }

    Start-Sleep -Seconds 2

    $runningWorker = Get-Process -Id $workerPid -ErrorAction SilentlyContinue

    if (-not $runningWorker) {
        $earlyLogs = @(Read-WorkerLogs)

        foreach ($line in $earlyLogs) {
            Write-Host $line
        }

        throw "Production worker exited immediately."
    }

    Write-Host ""
    Write-Host "REAL_PRODUCTION_WORKER_STARTED=PASS"
    Write-Host "WORKER_PID=$workerPid"
    Write-Host "CHILD_EXECUTION_OVERRIDE=false"
    Write-Host "CHILD_LIVE_TRADING_OVERRIDE=false"
    Write-Host "CHILD_MANAGEMENT_OVERRIDE=false"
    Write-Host "CHILD_DEMO_ONLY_OVERRIDE=true"

    # ---------------------------------------------------------
    # 5. OBSERVE REAL WORKER ACTIVITY
    # ---------------------------------------------------------

    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($maximumObservationSeconds)
    $activityCount = 0
    $dryRunActivityCount = 0
    $startupDryRunConfirmed = $false

    do {
        Start-Sleep -Seconds 3

        Confirm-Safety

        $bridgeNow = Get-BridgeHealth

        if ($bridgeNow.live_trading -ne $false) {
            throw "Bridge live trading changed during worker run."
        }

        if ($bridgeNow.management_enabled -ne $false) {
            throw "Bridge management changed during worker run."
        }

        if ($bridgeNow.mt5_connected -ne $true) {
            throw "Bridge lost MT5 during worker run."
        }

        $p = Get-Process -Id $workerPid -ErrorAction SilentlyContinue

        if (-not $p) {
            $logs = @(Read-WorkerLogs)

            foreach ($line in $logs) {
                Write-Host $line
            }

            throw "Production worker exited during observation."
        }

        $logs = @(Read-WorkerLogs)

        $startupLines = @(
            $logs |
            Where-Object {
                $_ -match 'ABUTRON v4 worker starting' -and
                $_ -match 'execution_enabled=False'
            }
        )

        if ($startupLines.Count -gt 0) {
            $startupDryRunConfirmed = $true
        }

        $activityLines = @(
            $logs |
            Where-Object {
                $_ -match 'confidence=' -and
                $_ -match 'risk=' -and
                $_ -match 'route=' -and
                $_ -match 'execution='
            }
        )

        $dryRunLines = @(
            $activityLines |
            Where-Object {
                $_ -match 'execution=None'
            }
        )

        $activityCount = $activityLines.Count
        $dryRunActivityCount = $dryRunLines.Count

        $elapsed = ((Get-Date) - $startedAt).TotalSeconds

        if (
            $elapsed -ge $minimumObservationSeconds -and
            $activityCount -ge $minimumActivityEvents -and
            $dryRunActivityCount -eq $activityCount -and
            $startupDryRunConfirmed
        ) {
            break
        }

    } while ((Get-Date) -lt $deadline)

    $elapsedFinal = [math]::Round(((Get-Date) - $startedAt).TotalSeconds,1)

    if (-not $startupDryRunConfirmed) {
        throw "Worker startup log did not confirm execution_enabled=False."
    }

    if ($activityCount -lt $minimumActivityEvents) {
        throw "Insufficient worker activity events: $activityCount."
    }

    if ($dryRunActivityCount -ne $activityCount) {
        throw "At least one worker activity event had a non-None execution result."
    }

    if ($elapsedFinal -lt $minimumObservationSeconds) {
        throw "Worker observation period was too short."
    }

    Write-Host ""
    Write-Host "WORKER_LIVE_LOOP_ACTIVITY=PASS"
    Write-Host "WORKER_ACTIVITY_EVENTS=$activityCount"
    Write-Host "WORKER_DRY_RUN_EVENTS=$dryRunActivityCount"
    Write-Host "WORKER_OBSERVATION_SECONDS=$elapsedFinal"
    Write-Host "WORKER_STARTUP_EXECUTION_DISABLED=PASS"

    # ---------------------------------------------------------
    # 6. STOP ONLY THE CERTIFICATION WORKER
    # ---------------------------------------------------------

    Stop-CertWorker

    $remainingWorkers = @(Get-WorkerProcesses)

    if ($remainingWorkers.Count -ne 0) {
        throw "Worker process remained after isolated test."
    }

    Write-Host "CERT_WORKER_STOPPED=PASS"
    Write-Host "WORKER_FINAL=OFF"

    # ---------------------------------------------------------
    # 7. POST-WORKER MT5 DEAL/POSITION PROBE
    # ---------------------------------------------------------

    $finalProbe = Run-MT5Probe -StartEpoch $testStartUnix

    if ($finalProbe["PROBE_INIT"] -ne "True") {
        throw "Final MT5 probe initialization failed."
    }

    if ($finalProbe["PROBE_CONNECTED"] -ne "True") {
        throw "Final MT5 probe is not connected."
    }

    if ($finalProbe["PROBE_SERVER_MATCH"] -ne "True") {
        throw "Final MT5 server mismatch."
    }

    if ($finalProbe["PROBE_HISTORY_OK"] -ne "True") {
        throw "Final deal history unavailable."
    }

    if ($finalProbe["PROBE_POSITIONS_OK"] -ne "True") {
        throw "Final positions unavailable."
    }

    $magicDeals = [int]$finalProbe["ABUTRON_MAGIC_DEALS"]
    $finalMagicPositions = [int]$finalProbe["ABUTRON_MAGIC_POSITIONS"]

    if ($magicDeals -ne 0) {
        throw "Abutron-magic deal(s) were created during Step 14A: $magicDeals."
    }

    if ($finalMagicPositions -ne $baselineMagicPositions) {
        throw "Abutron-magic position count changed during Step 14A."
    }

    Write-Host "NO_ABUTRON_MAGIC_DEALS=PASS"
    Write-Host "ABUTRON_MAGIC_DEALS=$magicDeals"
    Write-Host "MAGIC_POSITION_COUNT_UNCHANGED=PASS"

    # ---------------------------------------------------------
    # 8. FINAL PLATFORM CONTINUITY
    # ---------------------------------------------------------

    if ((Get-ListenerPid 8088) -ne $corePid) {
        throw "Core PID changed during Step 14A."
    }

    if ((Get-ListenerPid 8090) -ne $bridgePid) {
        throw "Bridge PID changed during Step 14A."
    }

    if ((Get-ListenerPid 8787) -ne $jarvisPid) {
        throw "Jarvis PID changed during Step 14A."
    }

    $mt5Final = @(Get-ExpectedMT5)

    if ($mt5Final.Count -ne 1) {
        throw "Final MT5 process count is not one."
    }

    if ([int]$mt5Final[0].ProcessId -ne $mt5Pid) {
        throw "MT5 restarted during Step 14A."
    }

    $coreFinal = Get-CoreHealth
    $bridgeFinal = Get-BridgeHealth

    if ($coreFinal.status -ne "ok") {
        throw "Core unhealthy after worker dry-run."
    }

    if ($coreFinal.kronos_loaded -ne $true) {
        throw "Kronos unloaded during worker dry-run."
    }

    if ($coreFinal.execution_enabled -ne $false) {
        throw "Core execution changed."
    }

    if ($bridgeFinal.mt5_connected -ne $true) {
        throw "Bridge lost MT5."
    }

    if ($bridgeFinal.live_trading -ne $false) {
        throw "Live trading changed."
    }

    if ($bridgeFinal.management_enabled -ne $false) {
        throw "Management changed."
    }

    if (-not (Get-JarvisObserveOnly)) {
        throw "Jarvis left OBSERVE_ONLY."
    }

    Confirm-Safety
    Confirm-WorkerOff

    $certified = $true
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    Stop-CertWorker

    try {
        $remaining = @(Get-WorkerProcesses)

        if ($remaining.Count -eq 0) {
            Write-Host "FAILSAFE_WORKER_OFF=PASS"
        }
        else {
            foreach ($item in $remaining) {
                Stop-Process `
                    -Id ([int]$item.ProcessId) `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            Start-Sleep -Seconds 2

            $afterKill = @(Get-WorkerProcesses)

            if ($afterKill.Count -eq 0) {
                Write-Host "FAILSAFE_WORKER_OFF=PASS"
            }
            else {
                Write-Host "FAILSAFE_WORKER_OFF=FAILED"
            }
        }
    }
    catch {
        Write-Host "FAILSAFE_WORKER_OFF=CHECK_REQUIRED"
    }

    try {
        Confirm-Safety
        Write-Host "FAILSAFE_EXECUTION_LOCKS=PASS"
    }
    catch {
        Write-Host "FAILSAFE_EXECUTION_LOCKS=CHECK_REQUIRED"
    }

    Remove-Item `
        $probeFile `
        -Force `
        -ErrorAction SilentlyContinue
}

if (-not $certified) {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 14A = NOT CERTIFIED"
    Write-Host "===================================================="
    Write-Host "FAILURE=$failureMessage"
    Write-Host "WORKER=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF_EXPECTED"
    Write-Host "LIVE_TRADING=OFF_EXPECTED"
    Write-Host "MANAGEMENT=OFF_EXPECTED"

    if (Test-Path $stderrLog) {
        Write-Host ""
        Write-Host "--- WORKER STDERR TAIL ---"
        Get-Content $stderrLog -Tail 80 -ErrorAction SilentlyContinue
    }

    if (Test-Path $stdoutLog) {
        Write-Host ""
        Write-Host "--- WORKER STDOUT TAIL ---"
        Get-Content $stdoutLog -Tail 80 -ErrorAction SilentlyContinue
    }

    exit 1
}

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 14A = PASS"
Write-Host "===================================================="
Write-Host "REAL_PRODUCTION_WORKER=PASS"
Write-Host "WORKER_EXECUTE_TRUE_PATH_EXERCISED=PASS"
Write-Host "SERVICE_EXECUTION_GUARD=PASS"
Write-Host "WORKER_STARTUP_EXECUTION_DISABLED=PASS"
Write-Host "WORKER_LIVE_LOOP_ACTIVITY=PASS"
Write-Host "WORKER_ACTIVITY_EVENTS=$activityCount"
Write-Host "WORKER_DRY_RUN_EVENTS=$dryRunActivityCount"
Write-Host "WORKER_OBSERVATION_SECONDS=$elapsedFinal"
Write-Host "WORKER_EXECUTION_RESULTS_NONE=PASS"
Write-Host "NO_ABUTRON_MAGIC_DEALS=PASS"
Write-Host "MAGIC_POSITION_COUNT_UNCHANGED=PASS"
Write-Host "CORE_PID_CONTINUITY=PASS"
Write-Host "BRIDGE_PID_CONTINUITY=PASS"
Write-Host "MT5_PID_CONTINUITY=PASS"
Write-Host "JARVIS_PID_CONTINUITY=PASS"
Write-Host "KRONOS_LOADED=True"
Write-Host "JARVIS_MODE=OBSERVE_ONLY"
Write-Host "WORKER_FINAL=OFF"
Write-Host "LIVE_TRADING=OFF"
Write-Host "MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "NO_TRADES_SENT"
Write-Host "===================================================="

exit 0
