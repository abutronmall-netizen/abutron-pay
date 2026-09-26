param(
    [ValidateRange(10,240)]
    [int]$ObservationMinutes = 30,

    [ValidateRange(5,60)]
    [int]$SampleSeconds = 10,

    [ValidateRange(3,1000)]
    [int]$MinimumActivityEvents = 10,

    [ValidateRange(60,900)]
    [int]$MaximumNoActivitySeconds = 240
)

$ErrorActionPreference = "Stop"

# =====================================================================
# ABUTRON STEP 14B
# PRODUCTION WORKER ENDURANCE / STABILITY CERTIFICATION
#
# Default test duration: 30 minutes.
#
# Purpose:
#   Run the REAL production abutron.worker continuously under hard
#   execution locks. Verify repeated live decision cycles, component
#   continuity, process/resource stability, MT5/Bridge continuity,
#   Jarvis OBSERVE_ONLY continuity, and zero Abutron trading changes.
#
# PASS DOES NOT AUTHORIZE:
#   - live execution
#   - worker persistence / auto-start
#   - demo order sending
#   - production go-live
# =====================================================================

$root       = "C:\Abutron\TradingPlatformV4"
$jarvisRoot = "C:\Abutron\Jarvis"

$envFile   = "$root\.env"
$jarvisEnv = "$jarvisRoot\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"

$workerFile  = "$root\abutron\worker.py"
$serviceFile = "$root\abutron\service.py"
$bridgeFile  = "$root\mt5_bridge\app.py"

$logDir = "$root\logs"

$runStamp  = Get-Date -Format "yyyyMMdd-HHmmss"
$stdoutLog = "$logDir\step14b_worker_${runStamp}_stdout.log"
$stderrLog = "$logDir\step14b_worker_${runStamp}_stderr.log"
$metricsCsv = "$logDir\step14b_metrics_${runStamp}.csv"
$summaryFile = "$logDir\step14b_summary_${runStamp}.txt"
$probeFile = "$root\scripts\step14b_mt5_probe.py"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$symbol = "XAUUSD"
$magic  = 400040

$certified = $false
$workerPid = $null
$failureMessage = ""

$baselineWorkerWorkingSetMB = $null
$baselineWorkerPrivateMB = $null
$baselineHandles = $null
$baselineThreads = $null
$baselineCpuSeconds = $null

$peakWorkerWorkingSetMB = 0.0
$peakWorkerPrivateMB = 0.0
$peakHandles = 0
$peakThreads = 0

$activityCount = 0
$dryRunActivityCount = 0
$startupDryRunConfirmed = $false
$lastActivityCount = 0
$lastActivityChangeAt = Get-Date

$testStartUnix = $null
$observationStartedAt = $null
$observationEndedAt = $null

function Get-EnvValue {
    param(
        [string]$File,
        [string]$Name
    )

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

    $json = $h | ConvertTo-Json -Depth 15 -Compress

    return (
        ($json -match '(?i)"mode"\s*:\s*"OBSERVE_ONLY"') -or
        ($json -match '(?i)"observe_only"\s*:\s*true')
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
}

function Confirm-NoUnexpectedWorker {
    param([int]$AllowedPid = 0)

    $workers = @(Get-WorkerProcesses)

    if ($AllowedPid -eq 0) {
        if ($workers.Count -ne 0) {
            throw "Unexpected production worker already running."
        }

        return
    }

    if ($workers.Count -ne 1) {
        throw "Expected exactly one certification worker; found $($workers.Count)."
    }

    if ([int]$workers[0].ProcessId -ne $AllowedPid) {
        throw "Unexpected worker PID detected: $($workers[0].ProcessId)."
    }
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

function Get-WorkerLogStats {
    $logs = @(Read-WorkerLogs)

    $startupLines = @(
        $logs |
        Where-Object {
            $_ -match 'ABUTRON v4 worker starting' -and
            $_ -match 'execution_enabled=False'
        }
    )

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

    $tracebacks = @(
        $logs |
        Where-Object {
            $_ -match 'Traceback \(most recent call last\)'
        }
    )

    return @{
        StartupDryRunConfirmed = ($startupLines.Count -gt 0)
        ActivityCount = $activityLines.Count
        DryRunActivityCount = $dryRunLines.Count
        TracebackCount = $tracebacks.Count
    }
}

function Stop-CertWorker {
    if ($workerPid) {
        $p = Get-Process `
            -Id $workerPid `
            -ErrorAction SilentlyContinue

        if ($p) {
            Stop-Process `
                -Id $workerPid `
                -Force `
                -ErrorAction SilentlyContinue

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
        ''
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

    $expectedServer = Get-EnvValue `
        $envFile `
        "MT5_EXPECTED_SERVER"

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

function Write-MetricRow {
    param(
        [datetime]$Timestamp,
        [double]$ElapsedSeconds,
        [System.Diagnostics.Process]$Process,
        [int]$ActivityEvents,
        [int]$DryRunEvents,
        [string]$CoreStatus,
        [bool]$KronosLoaded,
        [string]$BridgeStatus,
        [bool]$MT5Connected,
        [bool]$LiveTrading,
        [bool]$ManagementEnabled
    )

    $Process.Refresh()

    $workingSetMB = [math]::Round($Process.WorkingSet64 / 1MB,2)
    $privateMB = [math]::Round($Process.PrivateMemorySize64 / 1MB,2)
    $cpuSeconds = [math]::Round($Process.TotalProcessorTime.TotalSeconds,2)
    $handles = [int]$Process.HandleCount
    $threads = [int]$Process.Threads.Count

    if ($workingSetMB -gt $script:peakWorkerWorkingSetMB) {
        $script:peakWorkerWorkingSetMB = $workingSetMB
    }

    if ($privateMB -gt $script:peakWorkerPrivateMB) {
        $script:peakWorkerPrivateMB = $privateMB
    }

    if ($handles -gt $script:peakHandles) {
        $script:peakHandles = $handles
    }

    if ($threads -gt $script:peakThreads) {
        $script:peakThreads = $threads
    }

    $row = [pscustomobject]@{
        TimestampUtc      = $Timestamp.ToUniversalTime().ToString("o")
        ElapsedSeconds    = [math]::Round($ElapsedSeconds,1)
        WorkerPid         = $Process.Id
        WorkingSetMB      = $workingSetMB
        PrivateMemoryMB   = $privateMB
        CpuSeconds        = $cpuSeconds
        Handles           = $handles
        Threads           = $threads
        ActivityEvents    = $ActivityEvents
        DryRunEvents      = $DryRunEvents
        CoreStatus        = $CoreStatus
        KronosLoaded      = $KronosLoaded
        BridgeStatus      = $BridgeStatus
        MT5Connected      = $MT5Connected
        LiveTrading       = $LiveTrading
        ManagementEnabled = $ManagementEnabled
    }

    if (Test-Path $metricsCsv) {
        $row |
            Export-Csv `
                -Path $metricsCsv `
                -Append `
                -NoTypeInformation
    }
    else {
        $row |
            Export-Csv `
                -Path $metricsCsv `
                -NoTypeInformation
    }

    return $row
}

try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " ABUTRON - STEP 14B"
    Write-Host " PRODUCTION WORKER ENDURANCE / STABILITY"
    Write-Host " REAL WORKER / EXECUTION HARD-DISABLED"
    Write-Host "===================================================="
    Write-Host "OBSERVATION_MINUTES=$ObservationMinutes"
    Write-Host "SAMPLE_SECONDS=$SampleSeconds"
    Write-Host "MINIMUM_ACTIVITY_EVENTS=$MinimumActivityEvents"
    Write-Host "MAXIMUM_NO_ACTIVITY_SECONDS=$MaximumNoActivitySeconds"

    New-Item `
        -ItemType Directory `
        -Path $logDir `
        -Force |
        Out-Null

    Remove-Item $stdoutLog -Force -ErrorAction SilentlyContinue
    Remove-Item $stderrLog -Force -ErrorAction SilentlyContinue
    Remove-Item $metricsCsv -Force -ErrorAction SilentlyContinue
    Remove-Item $summaryFile -Force -ErrorAction SilentlyContinue

    # ---------------------------------------------------------
    # 1. STATIC PRODUCTION PATH AUDIT
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
        throw "Worker execute=True path changed."
    }

    if ($serviceSource -notmatch 'if\s+execute\s+and\s+settings\.execution_enabled\s+and\s+result\.plan') {
        throw "TradingService execution guard changed."
    }

    if ($serviceSource -notmatch 'gateway\.order\s*\(') {
        throw "TradingService gateway.order call not found."
    }

    if ($bridgeSource -notmatch 'MT5_LIVE_TRADING_FALSE') {
        throw "MT5 Bridge live-trading dry-run guard marker missing."
    }

    Write-Host "STATIC_PRODUCTION_PATH_AUDIT=PASS"
    Write-Host "WORKER_EXECUTE_TRUE_PATH=CONFIRMED"
    Write-Host "SERVICE_EXECUTION_GUARD=PASS"
    Write-Host "BRIDGE_LIVE_TRADING_GUARD=PASS"

    # ---------------------------------------------------------
    # 2. BASELINE SAFETY + COMPONENT OWNERSHIP
    # ---------------------------------------------------------

    Confirm-Safety
    Confirm-NoUnexpectedWorker

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
        throw "Core baseline unhealthy."
    }

    if ($coreHealth.kronos_loaded -ne $true) {
        throw "Kronos baseline not loaded."
    }

    if ($coreHealth.execution_enabled -ne $false) {
        throw "Core reports execution enabled."
    }

    if ($bridgeHealth.status -ne "ok") {
        throw "Bridge baseline unhealthy."
    }

    if ($bridgeHealth.mt5_connected -ne $true) {
        throw "Bridge baseline MT5 disconnected."
    }

    if ($bridgeHealth.live_trading -ne $false) {
        throw "Bridge live trading enabled."
    }

    if ($bridgeHealth.management_enabled -ne $false) {
        throw "Bridge management enabled."
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
    Write-Host "WORKER_BASELINE=OFF"
    Write-Host "LIVE_TRADING=OFF"
    Write-Host "MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"

    # ---------------------------------------------------------
    # 3. BASELINE READ-ONLY MT5 SNAPSHOT
    # ---------------------------------------------------------

    Write-ProbeFile
    $testStartUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $baselineProbe = Run-MT5Probe -StartEpoch $testStartUnix

    if ($baselineProbe["PROBE_INIT"] -ne "True") {
        throw "Baseline MT5 probe initialization failed."
    }

    if ($baselineProbe["PROBE_CONNECTED"] -ne "True") {
        throw "Baseline MT5 not connected."
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
    # 4. START REAL WORKER WITH CHILD-LOCAL HARD LOCKS
    # ---------------------------------------------------------

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

    Start-Sleep -Seconds 3

    $runningWorker = Get-Process `
        -Id $workerPid `
        -ErrorAction SilentlyContinue

    if (-not $runningWorker) {
        foreach ($line in @(Read-WorkerLogs)) {
            Write-Host $line
        }

        throw "Production worker exited immediately."
    }

    Confirm-NoUnexpectedWorker -AllowedPid $workerPid

    Write-Host "REAL_PRODUCTION_WORKER_STARTED=PASS"
    Write-Host "WORKER_PID=$workerPid"
    Write-Host "CHILD_EXECUTION_OVERRIDE=false"
    Write-Host "CHILD_LIVE_TRADING_OVERRIDE=false"
    Write-Host "CHILD_MANAGEMENT_OVERRIDE=false"
    Write-Host "CHILD_DEMO_ONLY_OVERRIDE=true"

    # ---------------------------------------------------------
    # 5. WARM-UP
    #    Establish resource baseline after actual live activity,
    #    not immediately after process creation/model loading.
    # ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- WORKER WARM-UP ---"

    $warmupDeadline = (Get-Date).AddSeconds(300)
    $warmupEvents = 0

    do {
        Start-Sleep -Seconds 5

        Confirm-Safety
        Confirm-NoUnexpectedWorker -AllowedPid $workerPid

        $p = Get-Process `
            -Id $workerPid `
            -ErrorAction SilentlyContinue

        if (-not $p) {
            throw "Worker exited during warm-up."
        }

        $stats = Get-WorkerLogStats

        if ($stats.TracebackCount -gt 0) {
            throw "Worker traceback detected during warm-up."
        }

        $warmupEvents = [int]$stats.ActivityCount
        $startupDryRunConfirmed = [bool]$stats.StartupDryRunConfirmed

        if (
            $warmupEvents -ge 2 -and
            $stats.DryRunActivityCount -eq $warmupEvents -and
            $startupDryRunConfirmed
        ) {
            break
        }

    } while ((Get-Date) -lt $warmupDeadline)

    if (-not $startupDryRunConfirmed) {
        throw "Worker startup did not confirm execution_enabled=False."
    }

    if ($warmupEvents -lt 2) {
        throw "Worker did not produce two live activity events during warm-up."
    }

    $warmupStats = Get-WorkerLogStats

    if ($warmupStats.DryRunActivityCount -ne $warmupStats.ActivityCount) {
        throw "Non-dry-run worker activity detected during warm-up."
    }

    $workerResourceBaseline = Get-Process `
        -Id $workerPid `
        -ErrorAction Stop

    $workerResourceBaseline.Refresh()

    $baselineWorkerWorkingSetMB = [math]::Round($workerResourceBaseline.WorkingSet64 / 1MB,2)
    $baselineWorkerPrivateMB = [math]::Round($workerResourceBaseline.PrivateMemorySize64 / 1MB,2)
    $baselineCpuSeconds = [math]::Round($workerResourceBaseline.TotalProcessorTime.TotalSeconds,2)
    $baselineHandles = [int]$workerResourceBaseline.HandleCount
    $baselineThreads = [int]$workerResourceBaseline.Threads.Count

    $peakWorkerWorkingSetMB = $baselineWorkerWorkingSetMB
    $peakWorkerPrivateMB = $baselineWorkerPrivateMB
    $peakHandles = $baselineHandles
    $peakThreads = $baselineThreads

    $activityCount = [int]$warmupStats.ActivityCount
    $dryRunActivityCount = [int]$warmupStats.DryRunActivityCount
    $lastActivityCount = $activityCount
    $lastActivityChangeAt = Get-Date

    Write-Host "WORKER_WARMUP=PASS"
    Write-Host "WARMUP_ACTIVITY_EVENTS=$activityCount"
    Write-Host "RESOURCE_BASELINE_WORKING_SET_MB=$baselineWorkerWorkingSetMB"
    Write-Host "RESOURCE_BASELINE_PRIVATE_MB=$baselineWorkerPrivateMB"
    Write-Host "RESOURCE_BASELINE_HANDLES=$baselineHandles"
    Write-Host "RESOURCE_BASELINE_THREADS=$baselineThreads"

    # ---------------------------------------------------------
    # 6. ENDURANCE OBSERVATION
    # ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- ENDURANCE OBSERVATION START ---"

    $observationStartedAt = Get-Date
    $observationDeadline = $observationStartedAt.AddMinutes($ObservationMinutes)
    $sampleIndex = 0
    $lastJarvisCheck = [datetime]::MinValue

    do {
        Start-Sleep -Seconds $SampleSeconds

        $sampleIndex += 1
        $now = Get-Date

        Confirm-Safety
        Confirm-NoUnexpectedWorker -AllowedPid $workerPid

        $p = Get-Process `
            -Id $workerPid `
            -ErrorAction SilentlyContinue

        if (-not $p) {
            throw "Production worker exited during endurance observation."
        }

        if ((Get-ListenerPid 8088) -ne $corePid) {
            throw "Core PID changed during endurance observation."
        }

        if ((Get-ListenerPid 8090) -ne $bridgePid) {
            throw "Bridge PID changed during endurance observation."
        }

        if ((Get-ListenerPid 8787) -ne $jarvisPid) {
            throw "Jarvis PID changed during endurance observation."
        }

        $mt5Now = @(Get-ExpectedMT5)

        if ($mt5Now.Count -ne 1) {
            throw "MT5 process count changed during endurance observation."
        }

        if ([int]$mt5Now[0].ProcessId -ne $mt5Pid) {
            throw "MT5 PID changed during endurance observation."
        }

        $coreNow = Get-CoreHealth
        $bridgeNow = Get-BridgeHealth

        if ($coreNow.status -ne "ok") {
            throw "Core health failed during endurance observation."
        }

        if ($coreNow.kronos_loaded -ne $true) {
            throw "Kronos unloaded during endurance observation."
        }

        if ($coreNow.execution_enabled -ne $false) {
            throw "Core execution became enabled."
        }

        if ($bridgeNow.status -ne "ok") {
            throw "Bridge health failed during endurance observation."
        }

        if ($bridgeNow.mt5_connected -ne $true) {
            throw "Bridge lost MT5 during endurance observation."
        }

        if ($bridgeNow.live_trading -ne $false) {
            throw "Bridge live trading became enabled."
        }

        if ($bridgeNow.management_enabled -ne $false) {
            throw "Bridge management became enabled."
        }

        if ((($now - $lastJarvisCheck).TotalSeconds) -ge 60) {
            if (-not (Get-JarvisObserveOnly)) {
                throw "Jarvis left OBSERVE_ONLY during endurance observation."
            }

            $lastJarvisCheck = $now
        }

        $logStats = Get-WorkerLogStats

        if ($logStats.TracebackCount -gt 0) {
            throw "Worker traceback detected during endurance observation."
        }

        $activityCount = [int]$logStats.ActivityCount
        $dryRunActivityCount = [int]$logStats.DryRunActivityCount
        $startupDryRunConfirmed = [bool]$logStats.StartupDryRunConfirmed

        if (-not $startupDryRunConfirmed) {
            throw "Worker startup dry-run evidence disappeared."
        }

        if ($dryRunActivityCount -ne $activityCount) {
            throw "At least one worker activity event had a non-None execution result."
        }

        if ($activityCount -gt $lastActivityCount) {
            $lastActivityCount = $activityCount
            $lastActivityChangeAt = $now
        }

        $noActivitySeconds = ($now - $lastActivityChangeAt).TotalSeconds

        if ($noActivitySeconds -gt $MaximumNoActivitySeconds) {
            throw "Worker produced no new decision activity for $([math]::Round($noActivitySeconds,1)) seconds."
        }

        $elapsedSeconds = ($now - $observationStartedAt).TotalSeconds

        $metricRow = Write-MetricRow `
            -Timestamp $now `
            -ElapsedSeconds $elapsedSeconds `
            -Process $p `
            -ActivityEvents $activityCount `
            -DryRunEvents $dryRunActivityCount `
            -CoreStatus ([string]$coreNow.status) `
            -KronosLoaded ([bool]$coreNow.kronos_loaded) `
            -BridgeStatus ([string]$bridgeNow.status) `
            -MT5Connected ([bool]$bridgeNow.mt5_connected) `
            -LiveTrading ([bool]$bridgeNow.live_trading) `
            -ManagementEnabled ([bool]$bridgeNow.management_enabled)

        if (($sampleIndex % 6) -eq 0) {
            Write-Host (
                "ENDURANCE_SAMPLE elapsed_s={0} events={1} ws_mb={2} private_mb={3} handles={4} threads={5}" -f `
                [math]::Round($elapsedSeconds,0),
                $activityCount,
                $metricRow.WorkingSetMB,
                $metricRow.PrivateMemoryMB,
                $metricRow.Handles,
                $metricRow.Threads
            )
        }

    } while ((Get-Date) -lt $observationDeadline)

    $observationEndedAt = Get-Date

    Write-Host "--- ENDURANCE OBSERVATION COMPLETE ---"

    # ---------------------------------------------------------
    # 7. FINAL RESOURCE / LIVENESS EVALUATION
    # ---------------------------------------------------------

    $finalWorker = Get-Process `
        -Id $workerPid `
        -ErrorAction Stop

    $finalWorker.Refresh()

    $finalWorkingSetMB = [math]::Round($finalWorker.WorkingSet64 / 1MB,2)
    $finalPrivateMB = [math]::Round($finalWorker.PrivateMemorySize64 / 1MB,2)
    $finalCpuSeconds = [math]::Round($finalWorker.TotalProcessorTime.TotalSeconds,2)
    $finalHandles = [int]$finalWorker.HandleCount
    $finalThreads = [int]$finalWorker.Threads.Count

    $workingSetGrowthMB = [math]::Round($finalWorkingSetMB - $baselineWorkerWorkingSetMB,2)
    $privateGrowthMB = [math]::Round($finalPrivateMB - $baselineWorkerPrivateMB,2)
    $handleGrowth = $finalHandles - $baselineHandles
    $threadGrowth = $finalThreads - $baselineThreads

    $workingSetGrowthPct = 0.0
    $privateGrowthPct = 0.0

    if ($baselineWorkerWorkingSetMB -gt 0) {
        $workingSetGrowthPct = [math]::Round(
            (($finalWorkingSetMB - $baselineWorkerWorkingSetMB) / $baselineWorkerWorkingSetMB) * 100.0,
            2
        )
    }

    if ($baselineWorkerPrivateMB -gt 0) {
        $privateGrowthPct = [math]::Round(
            (($finalPrivateMB - $baselineWorkerPrivateMB) / $baselineWorkerPrivateMB) * 100.0,
            2
        )
    }

    # Fail only on meaningful sustained growth after warm-up:
    # both a large absolute increase and a large relative increase.
    if (
        $workingSetGrowthMB -gt 512 -and
        $workingSetGrowthPct -gt 50
    ) {
        throw "Worker working-set growth exceeded endurance threshold: ${workingSetGrowthMB}MB / ${workingSetGrowthPct}%."
    }

    if (
        $privateGrowthMB -gt 512 -and
        $privateGrowthPct -gt 50
    ) {
        throw "Worker private-memory growth exceeded endurance threshold: ${privateGrowthMB}MB / ${privateGrowthPct}%."
    }

    if ($handleGrowth -gt 250) {
        throw "Worker handle count grew by $handleGrowth."
    }

    if ($threadGrowth -gt 20) {
        throw "Worker thread count grew by $threadGrowth."
    }

    $finalLogStats = Get-WorkerLogStats

    $activityCount = [int]$finalLogStats.ActivityCount
    $dryRunActivityCount = [int]$finalLogStats.DryRunActivityCount

    if ($activityCount -lt $MinimumActivityEvents) {
        throw "Insufficient endurance activity events: $activityCount; required $MinimumActivityEvents."
    }

    if ($dryRunActivityCount -ne $activityCount) {
        throw "Worker execution result was not None for every endurance event."
    }

    if ($finalLogStats.TracebackCount -ne 0) {
        throw "Worker traceback count is $($finalLogStats.TracebackCount)."
    }

    $observedMinutes = [math]::Round(
        ($observationEndedAt - $observationStartedAt).TotalMinutes,
        2
    )

    if ($observedMinutes -lt ($ObservationMinutes - 0.1)) {
        throw "Endurance observation ended too early: $observedMinutes minutes."
    }

    Write-Host "ENDURANCE_DURATION=PASS"
    Write-Host "OBSERVED_MINUTES=$observedMinutes"
    Write-Host "WORKER_ACTIVITY_EVENTS=$activityCount"
    Write-Host "WORKER_DRY_RUN_EVENTS=$dryRunActivityCount"
    Write-Host "WORKER_TRACEBACKS=0"

    Write-Host "RESOURCE_STABILITY=PASS"
    Write-Host "WORKER_BASELINE_WORKING_SET_MB=$baselineWorkerWorkingSetMB"
    Write-Host "WORKER_FINAL_WORKING_SET_MB=$finalWorkingSetMB"
    Write-Host "WORKER_PEAK_WORKING_SET_MB=$peakWorkerWorkingSetMB"
    Write-Host "WORKER_WORKING_SET_GROWTH_MB=$workingSetGrowthMB"
    Write-Host "WORKER_WORKING_SET_GROWTH_PCT=$workingSetGrowthPct"

    Write-Host "WORKER_BASELINE_PRIVATE_MB=$baselineWorkerPrivateMB"
    Write-Host "WORKER_FINAL_PRIVATE_MB=$finalPrivateMB"
    Write-Host "WORKER_PEAK_PRIVATE_MB=$peakWorkerPrivateMB"
    Write-Host "WORKER_PRIVATE_GROWTH_MB=$privateGrowthMB"
    Write-Host "WORKER_PRIVATE_GROWTH_PCT=$privateGrowthPct"

    Write-Host "WORKER_BASELINE_HANDLES=$baselineHandles"
    Write-Host "WORKER_FINAL_HANDLES=$finalHandles"
    Write-Host "WORKER_PEAK_HANDLES=$peakHandles"
    Write-Host "WORKER_HANDLE_GROWTH=$handleGrowth"

    Write-Host "WORKER_BASELINE_THREADS=$baselineThreads"
    Write-Host "WORKER_FINAL_THREADS=$finalThreads"
    Write-Host "WORKER_PEAK_THREADS=$peakThreads"
    Write-Host "WORKER_THREAD_GROWTH=$threadGrowth"

    Write-Host "WORKER_CPU_SECONDS_START=$baselineCpuSeconds"
    Write-Host "WORKER_CPU_SECONDS_FINAL=$finalCpuSeconds"

    # ---------------------------------------------------------
    # 8. STOP CERTIFICATION WORKER
    # ---------------------------------------------------------

    Stop-CertWorker

    Confirm-NoUnexpectedWorker

    Write-Host "CERT_WORKER_STOPPED=PASS"
    Write-Host "WORKER_FINAL=OFF"

    # ---------------------------------------------------------
    # 9. POST-ENDURANCE MT5 TRADE/POSITION PROBE
    # ---------------------------------------------------------

    $finalProbe = Run-MT5Probe -StartEpoch $testStartUnix

    if ($finalProbe["PROBE_INIT"] -ne "True") {
        throw "Final MT5 probe initialization failed."
    }

    if ($finalProbe["PROBE_CONNECTED"] -ne "True") {
        throw "Final MT5 not connected."
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
        throw "Abutron-magic deals were created during Step 14B: $magicDeals."
    }

    if ($finalMagicPositions -ne $baselineMagicPositions) {
        throw "Abutron-magic position count changed during Step 14B."
    }

    Write-Host "NO_ABUTRON_MAGIC_DEALS=PASS"
    Write-Host "ABUTRON_MAGIC_DEALS=$magicDeals"
    Write-Host "MAGIC_POSITION_COUNT_UNCHANGED=PASS"

    # ---------------------------------------------------------
    # 10. FINAL COMPONENT CONTINUITY
    # ---------------------------------------------------------

    if ((Get-ListenerPid 8088) -ne $corePid) {
        throw "Core PID changed during Step 14B."
    }

    if ((Get-ListenerPid 8090) -ne $bridgePid) {
        throw "Bridge PID changed during Step 14B."
    }

    if ((Get-ListenerPid 8787) -ne $jarvisPid) {
        throw "Jarvis PID changed during Step 14B."
    }

    $mt5Final = @(Get-ExpectedMT5)

    if ($mt5Final.Count -ne 1) {
        throw "Final MT5 process count is not one."
    }

    if ([int]$mt5Final[0].ProcessId -ne $mt5Pid) {
        throw "MT5 PID changed during Step 14B."
    }

    $coreFinal = Get-CoreHealth
    $bridgeFinal = Get-BridgeHealth

    if ($coreFinal.status -ne "ok") {
        throw "Core unhealthy after Step 14B."
    }

    if ($coreFinal.kronos_loaded -ne $true) {
        throw "Kronos unloaded during Step 14B."
    }

    if ($coreFinal.execution_enabled -ne $false) {
        throw "Core execution changed during Step 14B."
    }

    if ($bridgeFinal.status -ne "ok") {
        throw "Bridge unhealthy after Step 14B."
    }

    if ($bridgeFinal.mt5_connected -ne $true) {
        throw "Bridge lost MT5 after Step 14B."
    }

    if ($bridgeFinal.live_trading -ne $false) {
        throw "Live trading changed during Step 14B."
    }

    if ($bridgeFinal.management_enabled -ne $false) {
        throw "Management changed during Step 14B."
    }

    if (-not (Get-JarvisObserveOnly)) {
        throw "Jarvis left OBSERVE_ONLY."
    }

    Confirm-Safety
    Confirm-NoUnexpectedWorker

    # ---------------------------------------------------------
    # 11. EVIDENCE SUMMARY FILE
    # ---------------------------------------------------------

    $summary = @(
        "STEP_14B=PASS"
        "RUN_STAMP=$runStamp"
        "OBSERVATION_MINUTES=$observedMinutes"
        "WORKER_ACTIVITY_EVENTS=$activityCount"
        "WORKER_DRY_RUN_EVENTS=$dryRunActivityCount"
        "WORKER_TRACEBACKS=0"
        "WORKER_BASELINE_WORKING_SET_MB=$baselineWorkerWorkingSetMB"
        "WORKER_FINAL_WORKING_SET_MB=$finalWorkingSetMB"
        "WORKER_PEAK_WORKING_SET_MB=$peakWorkerWorkingSetMB"
        "WORKER_WORKING_SET_GROWTH_MB=$workingSetGrowthMB"
        "WORKER_WORKING_SET_GROWTH_PCT=$workingSetGrowthPct"
        "WORKER_BASELINE_PRIVATE_MB=$baselineWorkerPrivateMB"
        "WORKER_FINAL_PRIVATE_MB=$finalPrivateMB"
        "WORKER_PEAK_PRIVATE_MB=$peakWorkerPrivateMB"
        "WORKER_PRIVATE_GROWTH_MB=$privateGrowthMB"
        "WORKER_PRIVATE_GROWTH_PCT=$privateGrowthPct"
        "WORKER_HANDLE_GROWTH=$handleGrowth"
        "WORKER_THREAD_GROWTH=$threadGrowth"
        "ABUTRON_MAGIC_DEALS=0"
        "ABUTRON_MAGIC_POSITIONS_BASELINE=$baselineMagicPositions"
        "ABUTRON_MAGIC_POSITIONS_FINAL=$finalMagicPositions"
        "CORE_PID=$corePid"
        "BRIDGE_PID=$bridgePid"
        "MT5_PID=$mt5Pid"
        "JARVIS_PID=$jarvisPid"
        "KRONOS_LOADED=True"
        "JARVIS_MODE=OBSERVE_ONLY"
        "WORKER_FINAL=OFF"
        "LIVE_TRADING=OFF"
        "MANAGEMENT=OFF"
        "ABUTRON_EXECUTION=OFF"
        "NO_TRADES_SENT"
        "METRICS_CSV=$metricsCsv"
        "WORKER_STDOUT=$stdoutLog"
        "WORKER_STDERR=$stderrLog"
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
    Stop-CertWorker

    try {
        $remainingWorkers = @(Get-WorkerProcesses)

        if ($remainingWorkers.Count -gt 0) {
            foreach ($item in $remainingWorkers) {
                Stop-Process `
                    -Id ([int]$item.ProcessId) `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            Start-Sleep -Seconds 2
        }

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
    Write-Host " STEP 14B = NOT CERTIFIED"
    Write-Host "===================================================="
    Write-Host "FAILURE=$failureMessage"
    Write-Host "WORKER=OFF_EXPECTED"
    Write-Host "LIVE_TRADING=OFF_EXPECTED"
    Write-Host "MANAGEMENT=OFF_EXPECTED"
    Write-Host "ABUTRON_EXECUTION=OFF_EXPECTED"
    Write-Host "METRICS_CSV=$metricsCsv"
    Write-Host "WORKER_STDOUT=$stdoutLog"
    Write-Host "WORKER_STDERR=$stderrLog"

    if (Test-Path $stderrLog) {
        Write-Host ""
        Write-Host "--- WORKER STDERR TAIL ---"

        Get-Content `
            $stderrLog `
            -Tail 100 `
            -ErrorAction SilentlyContinue
    }

    if (Test-Path $stdoutLog) {
        Write-Host ""
        Write-Host "--- WORKER STDOUT TAIL ---"

        Get-Content `
            $stdoutLog `
            -Tail 100 `
            -ErrorAction SilentlyContinue
    }

    exit 1
}

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 14B = PASS"
Write-Host "===================================================="
Write-Host "REAL_PRODUCTION_WORKER_ENDURANCE=PASS"
Write-Host "ENDURANCE_DURATION=PASS"
Write-Host "OBSERVED_MINUTES=$observedMinutes"
Write-Host "WORKER_ACTIVITY_EVENTS=$activityCount"
Write-Host "WORKER_DRY_RUN_EVENTS=$dryRunActivityCount"
Write-Host "WORKER_EXECUTION_RESULTS_NONE=PASS"
Write-Host "WORKER_TRACEBACKS=0"
Write-Host "RESOURCE_STABILITY=PASS"
Write-Host "WORKER_WORKING_SET_GROWTH_MB=$workingSetGrowthMB"
Write-Host "WORKER_WORKING_SET_GROWTH_PCT=$workingSetGrowthPct"
Write-Host "WORKER_PRIVATE_GROWTH_MB=$privateGrowthMB"
Write-Host "WORKER_PRIVATE_GROWTH_PCT=$privateGrowthPct"
Write-Host "WORKER_HANDLE_GROWTH=$handleGrowth"
Write-Host "WORKER_THREAD_GROWTH=$threadGrowth"
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
Write-Host "METRICS_CSV=$metricsCsv"
Write-Host "SUMMARY_FILE=$summaryFile"
Write-Host "WORKER_STDOUT=$stdoutLog"
Write-Host "WORKER_STDERR=$stderrLog"
Write-Host "===================================================="

exit 0
