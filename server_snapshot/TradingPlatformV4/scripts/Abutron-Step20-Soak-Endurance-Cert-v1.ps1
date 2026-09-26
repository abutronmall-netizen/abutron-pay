param(
    [ValidateRange(15,1440)]
    [int]$DurationMinutes = 120,

    [ValidateRange(10,120)]
    [int]$SampleSeconds = 15,

    [ValidateRange(60,600)]
    [int]$InfrastructureProbeSeconds = 120,

    [ValidateRange(120,900)]
    [int]$MaximumNoActivitySeconds = 360,

    [switch]$DiagnosticOnly
)

$ErrorActionPreference = "Stop"

# =====================================================================
# ABUTRON STEP 20 V1
# FULL-STACK SOAK / ENDURANCE CERTIFICATION
#
# Certification mode requires >=120 minutes.
# It runs the REAL production worker only in an isolated child process
# with execution/live-trading/management hard-disabled.
# No order endpoint is intentionally called and no live-money trading is
# authorized. The production .env is never modified.
# =====================================================================

$root       = "C:\Abutron\TradingPlatformV4"
$jarvisRoot = "C:\Abutron\Jarvis"
$envFile    = "$root\.env"
$jarvisEnv  = "$jarvisRoot\.env"
$pythonExe  = "$root\.venv\Scripts\python.exe"
$helper     = "$root\scripts\step20_soak_probe_v1.py"
$mt5Path    = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"
$logDir     = "$root\logs"
$certFile   = "$logDir\step20_certification.json"

$expectedHelperHash = "F4612987C17CCBE4208748D0828A78C116C694E2D402D24ACF0235B62F5ED470"
$buildMarker = "STEP20_SOAK_ENDURANCE_CERT_V1"
$magic = 400040

if (-not $DiagnosticOnly -and $DurationMinutes -lt 120) {
    throw "STEP20 certification requires at least 120 minutes. Use -DiagnosticOnly for shorter diagnostics."
}

$runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$metricsCsv = "$logDir\step20_soak_${runStamp}_metrics.csv"
$workerStdout = "$logDir\step20_worker_${runStamp}_stdout.log"
$workerStderr = "$logDir\step20_worker_${runStamp}_stderr.log"
$summaryFile = "$logDir\step20_summary_${runStamp}.json"

$workerPid = $null
$certified = $false
$failure = ""
$startEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$startedUtc = [DateTime]::UtcNow

function Get-EnvValue {
    param([string]$File,[string]$Name)
    $escaped = [regex]::Escape($Name)
    $line = Get-Content $File | Where-Object { $_ -match "^\s*$escaped\s*=" } | Select-Object -First 1
    if (-not $line) { return $null }
    return (($line -split "=",2)[1]).Trim().Trim('"').Trim("'")
}

function Get-ListenerPid {
    param([int]$Port)
    $x = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $x) { return $null }
    return [int]$x.OwningProcess
}

function Get-WorkerProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "(?i)(-m\s+abutron\.worker|abutron\\worker\.py)" })
}

function Confirm-Safety {
    $exec = [string](Get-EnvValue $envFile "ABUTRON_EXECUTION_ENABLED")
    $live = [string](Get-EnvValue $envFile "MT5_LIVE_TRADING")
    $mgmt = [string](Get-EnvValue $envFile "MT5_MANAGEMENT_ENABLED")
    $demo = [string](Get-EnvValue $envFile "MT5_DEMO_ONLY")
    if ($exec.ToLowerInvariant() -ne "false") { throw "ABUTRON_EXECUTION_ENABLED must remain false." }
    if ($live.ToLowerInvariant() -ne "false") { throw "MT5_LIVE_TRADING must remain false." }
    if ($mgmt.ToLowerInvariant() -ne "false") { throw "MT5_MANAGEMENT_ENABLED must remain false." }
    if ($demo.ToLowerInvariant() -ne "true") { throw "MT5_DEMO_ONLY must remain true." }
}

function Get-OwnerInfo {
    param([int]$PidValue)
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$PidValue" -ErrorAction Stop
    $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
    return @{ Process=$p; User=$o.User; Domain=$o.Domain; Owner="$($o.Domain)\$($o.User)" }
}

function Get-ExpectedMT5 {
    return @(Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq "terminal64.exe" -and $_.ExecutablePath -ieq $mt5Path })
}

function Get-JarvisObserveOnly {
    $token = Get-EnvValue $jarvisEnv "JARVIS_API_TOKEN"
    if ([string]::IsNullOrWhiteSpace($token)) { throw "Jarvis API token unavailable." }
    $headers = @{ "X-Jarvis-Token" = $token }
    $h = Invoke-RestMethod -Uri "http://127.0.0.1:8787/v1/system/health" -Headers $headers -TimeoutSec 60
    $json = $h | ConvertTo-Json -Depth 15 -Compress
    return (($json -match '(?i)"mode"\s*:\s*"OBSERVE_ONLY"') -or ($json -match '(?i)"observe_only"\s*:\s*true'))
}

function Get-WorkerTreeProcessObjects {
    param([int]$RootPid)
    $all = @(Get-CimInstance Win32_Process)
    $ids = New-Object "System.Collections.Generic.HashSet[int]"
    $null = $ids.Add($RootPid)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($item in $all) {
            $parentId = [int]$item.ParentProcessId
            $processId = [int]$item.ProcessId
            if ($ids.Contains($parentId) -and -not $ids.Contains($processId)) {
                $null = $ids.Add($processId)
                $changed = $true
            }
        }
    }
    $workers = @(Get-WorkerProcesses)
    $unexpected = @($workers | Where-Object { -not $ids.Contains([int]$_.ProcessId) })
    if ($unexpected.Count -gt 0) { throw "Unexpected worker outside certification tree." }
    $objects = @()
    foreach ($item in ($workers | Where-Object { $ids.Contains([int]$_.ProcessId) })) {
        $p = Get-Process -Id ([int]$item.ProcessId) -ErrorAction SilentlyContinue
        if ($p) { $objects += $p }
    }
    if ($objects.Count -lt 1) { throw "Certification worker tree disappeared." }
    return @($objects)
}

function Get-ProcessSnapshot {
    param([int]$PidValue)
    $p = Get-Process -Id $PidValue -ErrorAction Stop
    $p.Refresh()
    return [pscustomobject]@{
        WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB,2)
        PrivateMB = [math]::Round($p.PrivateMemorySize64 / 1MB,2)
        Handles = [int]$p.HandleCount
        Threads = [int]$p.Threads.Count
        CpuSeconds = [math]::Round($p.TotalProcessorTime.TotalSeconds,2)
    }
}

function Get-WorkerSnapshot {
    param([int]$RootPid)
    $items = @(Get-WorkerTreeProcessObjects -RootPid $RootPid)
    $ws=0.0; $priv=0.0; $handles=0; $threads=0; $cpu=0.0
    foreach ($p in $items) {
        $p.Refresh(); $ws += $p.WorkingSet64/1MB; $priv += $p.PrivateMemorySize64/1MB
        $handles += $p.HandleCount; $threads += $p.Threads.Count; $cpu += $p.TotalProcessorTime.TotalSeconds
    }
    return [pscustomobject]@{
        WorkingSetMB=[math]::Round($ws,2); PrivateMB=[math]::Round($priv,2); Handles=$handles; Threads=$threads; CpuSeconds=[math]::Round($cpu,2)
    }
}

function Get-SystemSnapshot {
    $os = Get-CimInstance Win32_OperatingSystem
    $cpus = @(Get-CimInstance Win32_Processor)
    $cpu = 0.0
    if ($cpus.Count -gt 0) { $cpu = [math]::Round((($cpus | Measure-Object -Property LoadPercentage -Average).Average),2) }
    $totalMB = [double]$os.TotalVisibleMemorySize / 1024.0
    $freeMB = [double]$os.FreePhysicalMemory / 1024.0
    $freePct = if ($totalMB -gt 0) { [math]::Round(($freeMB/$totalMB)*100.0,2) } else { 0.0 }
    return [pscustomobject]@{ CpuPct=$cpu; TotalMemoryMB=[math]::Round($totalMB,2); FreeMemoryMB=[math]::Round($freeMB,2); FreeMemoryPct=$freePct }
}

function Read-WorkerStats {
    $lines = @()
    if (Test-Path $workerStdout) { $lines += @(Get-Content $workerStdout -ErrorAction SilentlyContinue) }
    if (Test-Path $workerStderr) { $lines += @(Get-Content $workerStderr -ErrorAction SilentlyContinue) }
    $startup = @($lines | Where-Object { $_ -match 'ABUTRON v4 worker starting' -and $_ -match 'execution_enabled=False' }).Count
    $activity = @($lines | Where-Object { $_ -match 'confidence=' -and $_ -match 'risk=' -and $_ -match 'route=' -and $_ -match 'execution=' })
    $dry = @($activity | Where-Object { $_ -match 'execution=None' })
    $trace = @($lines | Where-Object { $_ -match 'Traceback \(most recent call last\)' }).Count
    return @{ Startup=$startup; Activity=$activity.Count; Dry=$dry.Count; Tracebacks=$trace }
}

function Invoke-TimedRest {
    param([string]$Uri,[int]$TimeoutSec=30)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-RestMethod -Uri $Uri -TimeoutSec $TimeoutSec
    $sw.Stop()
    return @{ Result=$result; Ms=[math]::Round($sw.Elapsed.TotalMilliseconds,2) }
}

function Invoke-InfraHelper {
    $out = @(& $pythonExe $helper --mode infra 2>&1)
    $exit = $LASTEXITCODE
    foreach ($line in $out) { Write-Host ([string]$line) }
    if ($exit -ne 0) { throw "Step20 infrastructure helper failed with exit code $exit." }
}

function Invoke-MT5Helper {
    param([long]$StartEpoch)
    $out = @(& $pythonExe $helper --mode mt5 --mt5-path $mt5Path --start-epoch $StartEpoch 2>&1)
    $exit = $LASTEXITCODE
    foreach ($line in $out) { Write-Host ([string]$line) }
    if ($exit -ne 0) { throw "Step20 MT5 helper failed with exit code $exit." }
}

function Confirm-HTTPMonitoring {
    $prom = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:9090/-/healthy" -TimeoutSec 15
    if ($prom.StatusCode -ne 200) { throw "Prometheus health failed." }
    $graf = Invoke-RestMethod -Uri "http://127.0.0.1:3000/api/health" -TimeoutSec 15
    if (-not $graf) { throw "Grafana health failed." }
    $exporter = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:9182/metrics" -TimeoutSec 20
    if ($exporter.StatusCode -ne 200) { throw "Windows exporter health failed." }
}

function Stop-CertWorker {
    if ($workerPid) {
        foreach ($item in (@(Get-WorkerProcesses) | Sort-Object ProcessId -Descending)) {
            Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2
    }
}

function Assert-ResourceGrowth {
    param([string]$Name,$Baseline,$Final)
    $wsGrow = [double]$Final.WorkingSetMB - [double]$Baseline.WorkingSetMB
    $privGrow = [double]$Final.PrivateMB - [double]$Baseline.PrivateMB
    $wsPct = if ([double]$Baseline.WorkingSetMB -gt 0) { ($wsGrow/[double]$Baseline.WorkingSetMB)*100.0 } else { 0 }
    $privPct = if ([double]$Baseline.PrivateMB -gt 0) { ($privGrow/[double]$Baseline.PrivateMB)*100.0 } else { 0 }
    if ($wsGrow -gt 512 -and $wsPct -gt 50) { throw "$Name working-set growth exceeded threshold." }
    if ($privGrow -gt 512 -and $privPct -gt 50) { throw "$Name private-memory growth exceeded threshold." }
    if (([int]$Final.Handles - [int]$Baseline.Handles) -gt 250) { throw "$Name handle growth exceeded threshold." }
    if (([int]$Final.Threads - [int]$Baseline.Threads) -gt 20) { throw "$Name thread growth exceeded threshold." }
}

try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " ABUTRON STEP 20 - SOAK / ENDURANCE CERTIFICATION V1"
    Write-Host " FULL STACK / REAL WORKER / EXECUTION HARD-DISABLED"
    Write-Host "===================================================="
    Write-Host "DURATION_MINUTES=$DurationMinutes"
    Write-Host "SAMPLE_SECONDS=$SampleSeconds"
    Write-Host "DIAGNOSTIC_ONLY=$([bool]$DiagnosticOnly)"
    Write-Host "LIVE_MONEY_AUTHORIZED=False"

    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    foreach ($required in @($envFile,$jarvisEnv,$pythonExe,$helper,$mt5Path)) {
        if (-not (Test-Path $required)) { throw "Required Step20 prerequisite missing: $required" }
    }

    Confirm-Safety
    if (@(Get-WorkerProcesses).Count -ne 0) { throw "Production worker must be OFF before Step20." }

    $helperHash = (Get-FileHash $helper -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($helperHash -ne $expectedHelperHash) { throw "Step20 helper SHA256 mismatch." }
    & $pythonExe -m py_compile $helper
    if ($LASTEXITCODE -ne 0) { throw "Step20 helper Python syntax failed." }

    $criticalFiles = @(
        "$root\abutron\worker.py",
        "$root\abutron\service.py",
        "$root\abutron\profiles.py",
        "$root\abutron\router.py",
        "$root\abutron\risk.py",
        "$root\abutron\capital.py",
        "$root\abutron\strategies.py",
        "$root\abutron\platform_db.py",
        "$root\mt5_bridge\app.py"
    )
    foreach ($f in $criticalFiles) { if (-not (Test-Path $f)) { throw "Critical source missing: $f" } }
    $sourceHashes = @{}
    foreach ($f in $criticalFiles) { $sourceHashes[$f] = (Get-FileHash $f -Algorithm SHA256).Hash.ToUpperInvariant() }
    $envHash = (Get-FileHash $envFile -Algorithm SHA256).Hash.ToUpperInvariant()

    $preflightOut = @(& $pythonExe $helper --mode preflight --mt5-path $mt5Path 2>&1)
    $preflightExit = $LASTEXITCODE
    foreach ($line in $preflightOut) { Write-Host ([string]$line) }
    if ($preflightExit -ne 0) { throw "Step20 helper preflight failed." }

    $corePid = Get-ListenerPid 8088
    $bridgePid = Get-ListenerPid 8090
    $jarvisPid = Get-ListenerPid 8787
    $promPid = Get-ListenerPid 9090
    $grafanaPid = Get-ListenerPid 3000
    $exporterPid = Get-ListenerPid 9182
    if (-not $corePid) { throw "Core listener missing." }
    if (-not $bridgePid) { throw "Bridge listener missing." }
    if (-not $jarvisPid) { throw "Jarvis listener missing." }
    if (-not $promPid) { throw "Prometheus listener missing." }
    if (-not $grafanaPid) { throw "Grafana listener missing." }
    if (-not $exporterPid) { throw "Windows exporter listener missing." }

    $mt5 = @(Get-ExpectedMT5)
    if ($mt5.Count -ne 1) { throw "Expected exactly one MT5 terminal." }
    $mt5Pid = [int]$mt5[0].ProcessId
    $mt5Session = [int]$mt5[0].SessionId
    $bridgeOwner = Get-OwnerInfo $bridgePid
    $mt5Owner = Get-OwnerInfo $mt5Pid
    if ($bridgeOwner.User -ine "Administrator") { throw "Bridge owner must be Administrator." }
    if ($mt5Owner.User -ine "Administrator") { throw "MT5 owner must be Administrator." }
    if ([int]$bridgeOwner.Process.SessionId -ne $mt5Session) { throw "Bridge and MT5 session mismatch." }

    $coreBaseCall = Invoke-TimedRest "http://127.0.0.1:8088/health"
    $bridgeBaseCall = Invoke-TimedRest "http://127.0.0.1:8090/health"
    if ($coreBaseCall.Result.status -ne "ok" -or $coreBaseCall.Result.kronos_loaded -ne $true -or $coreBaseCall.Result.execution_enabled -ne $false) { throw "Core/Kronos baseline failed." }
    if ($bridgeBaseCall.Result.status -ne "ok" -or $bridgeBaseCall.Result.mt5_connected -ne $true -or $bridgeBaseCall.Result.live_trading -ne $false -or $bridgeBaseCall.Result.management_enabled -ne $false) { throw "Bridge baseline failed." }
    if (-not (Get-JarvisObserveOnly)) { throw "Jarvis is not OBSERVE_ONLY." }
    Confirm-HTTPMonitoring

    $coreBase = Get-ProcessSnapshot $corePid
    $bridgeBase = Get-ProcessSnapshot $bridgePid
    $jarvisBase = Get-ProcessSnapshot $jarvisPid

    Write-Host "STEP20_BASELINE=PASS"
    Write-Host "STEP20_STEP19_3_OF_3=PASS"
    Write-Host "WORKER_BASELINE=OFF"
    Write-Host "PRODUCTION_ENV_CHANGED=False"

    $envBackup = @{
        "ABUTRON_EXECUTION_ENABLED" = [Environment]::GetEnvironmentVariable("ABUTRON_EXECUTION_ENABLED","Process")
        "MT5_LIVE_TRADING" = [Environment]::GetEnvironmentVariable("MT5_LIVE_TRADING","Process")
        "MT5_MANAGEMENT_ENABLED" = [Environment]::GetEnvironmentVariable("MT5_MANAGEMENT_ENABLED","Process")
        "MT5_DEMO_ONLY" = [Environment]::GetEnvironmentVariable("MT5_DEMO_ONLY","Process")
    }
    try {
        [Environment]::SetEnvironmentVariable("ABUTRON_EXECUTION_ENABLED","false","Process")
        [Environment]::SetEnvironmentVariable("MT5_LIVE_TRADING","false","Process")
        [Environment]::SetEnvironmentVariable("MT5_MANAGEMENT_ENABLED","false","Process")
        [Environment]::SetEnvironmentVariable("MT5_DEMO_ONLY","true","Process")
        $wp = Start-Process -FilePath $pythonExe -ArgumentList @("-m","abutron.worker") -WorkingDirectory $root -RedirectStandardOutput $workerStdout -RedirectStandardError $workerStderr -PassThru
        $workerPid = [int]$wp.Id
    }
    finally {
        foreach ($name in $envBackup.Keys) { [Environment]::SetEnvironmentVariable($name,$envBackup[$name],"Process") }
    }

    $warmDeadline = (Get-Date).AddSeconds(360)
    do {
        Start-Sleep -Seconds 5
        Confirm-Safety
        $stats = Read-WorkerStats
        if ($stats.Tracebacks -gt 0) { throw "Worker traceback during warm-up." }
        if ($stats.Startup -gt 0 -and $stats.Activity -ge 2 -and $stats.Dry -eq $stats.Activity) { break }
    } while ((Get-Date) -lt $warmDeadline)
    $stats = Read-WorkerStats
    if ($stats.Startup -lt 1 -or $stats.Activity -lt 2 -or $stats.Dry -ne $stats.Activity) { throw "Worker warm-up did not establish safe dry-run activity." }

    $workerBase = Get-WorkerSnapshot $workerPid
    $lastActivity = [int]$stats.Activity
    $lastActivityAt = Get-Date
    $observationStart = Get-Date
    $deadline = $observationStart.AddMinutes($DurationMinutes)
    $lastInfra = [datetime]::MinValue
    $lastMonitoring = [datetime]::MinValue
    $lastDataProbe = [datetime]::MinValue
    $sampleIndex = 0
    $latencies = New-Object System.Collections.Generic.List[double]
    $infraProbeCount = 0
    $dataProbeCount = 0
    $peakCpu = 0.0
    $minFreeMemoryPct = 100.0

    Write-Host "STEP20_WORKER_WARMUP=PASS"
    Write-Host "STEP20_OBSERVATION_START=$($observationStart.ToUniversalTime().ToString('o'))"

    do {
        Start-Sleep -Seconds $SampleSeconds
        $now = Get-Date
        $sampleIndex++
        Confirm-Safety
        $workers = @(Get-WorkerTreeProcessObjects -RootPid $workerPid)
        if ($workers.Count -lt 1) { throw "Worker tree missing during soak." }

        if ((Get-ListenerPid 8088) -ne $corePid) { throw "Core PID changed during soak." }
        if ((Get-ListenerPid 8090) -ne $bridgePid) { throw "Bridge PID changed during soak." }
        if ((Get-ListenerPid 8787) -ne $jarvisPid) { throw "Jarvis PID changed during soak." }
        if ((Get-ListenerPid 9090) -ne $promPid) { throw "Prometheus PID changed during soak." }
        if ((Get-ListenerPid 3000) -ne $grafanaPid) { throw "Grafana PID changed during soak." }
        if ((Get-ListenerPid 9182) -ne $exporterPid) { throw "Windows exporter PID changed during soak." }
        $mt5Now = @(Get-ExpectedMT5)
        if ($mt5Now.Count -ne 1 -or [int]$mt5Now[0].ProcessId -ne $mt5Pid) { throw "MT5 process changed during soak." }

        $coreCall = Invoke-TimedRest "http://127.0.0.1:8088/health"
        $bridgeCall = Invoke-TimedRest "http://127.0.0.1:8090/health"
        $latencies.Add([double]$coreCall.Ms); $latencies.Add([double]$bridgeCall.Ms)
        if ($coreCall.Result.status -ne "ok" -or $coreCall.Result.kronos_loaded -ne $true -or $coreCall.Result.execution_enabled -ne $false) { throw "Core health/safety failed during soak." }
        if ($bridgeCall.Result.status -ne "ok" -or $bridgeCall.Result.mt5_connected -ne $true -or $bridgeCall.Result.live_trading -ne $false -or $bridgeCall.Result.management_enabled -ne $false) { throw "Bridge health/safety failed during soak." }

        $stats = Read-WorkerStats
        if ($stats.Tracebacks -gt 0) { throw "Worker traceback detected during soak." }
        if ($stats.Dry -ne $stats.Activity) { throw "Non-dry-run worker activity detected." }
        if ([int]$stats.Activity -gt $lastActivity) { $lastActivity = [int]$stats.Activity; $lastActivityAt = $now }
        if (($now - $lastActivityAt).TotalSeconds -gt $MaximumNoActivitySeconds) { throw "Worker decision activity stalled beyond threshold." }

        if (($now - $lastInfra).TotalSeconds -ge $InfrastructureProbeSeconds) {
            Invoke-InfraHelper
            $infraProbeCount++
            $lastInfra = $now
        }
        if (($now - $lastMonitoring).TotalSeconds -ge 60) {
            if (-not (Get-JarvisObserveOnly)) { throw "Jarvis left OBSERVE_ONLY." }
            Confirm-HTTPMonitoring
            $lastMonitoring = $now
        }
        if (($now - $lastDataProbe).TotalSeconds -ge 120) {
            foreach ($uri in @(
                "http://127.0.0.1:8090/v1/bars/XAUUSD?timeframe=M1&count=32",
                "http://127.0.0.1:8090/v1/bars/XAUUSD?timeframe=M5&count=32",
                "http://127.0.0.1:8090/v1/bars/XAUUSD?timeframe=M15&count=32",
                "http://127.0.0.1:8090/v1/bars/XAUUSD?timeframe=H1&count=32",
                "http://127.0.0.1:8090/v1/bars/XAUUSD?timeframe=H4&count=32",
                "http://127.0.0.1:8090/v1/context/XAUUSD"
            )) {
                $call = Invoke-TimedRest $uri 30
                $latencies.Add([double]$call.Ms)
            }
            $dataProbeCount++
            $lastDataProbe = $now
        }

        $system = Get-SystemSnapshot
        if ([double]$system.CpuPct -gt $peakCpu) { $peakCpu = [double]$system.CpuPct }
        if ([double]$system.FreeMemoryPct -lt $minFreeMemoryPct) { $minFreeMemoryPct = [double]$system.FreeMemoryPct }
        if ([double]$system.FreeMemoryMB -lt 512 -or [double]$system.FreeMemoryPct -lt 5) { throw "System memory pressure exceeded Step20 threshold." }

        $workerSnap = Get-WorkerSnapshot $workerPid
        $coreSnap = Get-ProcessSnapshot $corePid
        $bridgeSnap = Get-ProcessSnapshot $bridgePid
        $jarvisSnap = Get-ProcessSnapshot $jarvisPid
        $row = [pscustomobject]@{
            TimestampUtc=$now.ToUniversalTime().ToString('o'); ElapsedSeconds=[math]::Round(($now-$observationStart).TotalSeconds,1)
            ActivityEvents=[int]$stats.Activity; DryRunEvents=[int]$stats.Dry
            CoreLatencyMs=[double]$coreCall.Ms; BridgeLatencyMs=[double]$bridgeCall.Ms
            WorkerWorkingSetMB=$workerSnap.WorkingSetMB; WorkerPrivateMB=$workerSnap.PrivateMB; WorkerHandles=$workerSnap.Handles; WorkerThreads=$workerSnap.Threads
            CoreWorkingSetMB=$coreSnap.WorkingSetMB; BridgeWorkingSetMB=$bridgeSnap.WorkingSetMB; JarvisWorkingSetMB=$jarvisSnap.WorkingSetMB
            SystemCpuPct=$system.CpuPct; FreeMemoryMB=$system.FreeMemoryMB; FreeMemoryPct=$system.FreeMemoryPct
        }
        if (Test-Path $metricsCsv) { $row | Export-Csv -Path $metricsCsv -Append -NoTypeInformation } else { $row | Export-Csv -Path $metricsCsv -NoTypeInformation }
        if (($sampleIndex % 20) -eq 0) { Write-Host ("STEP20_SAMPLE elapsed_min={0} events={1} cpu_pct={2} free_mem_pct={3}" -f [math]::Round(($now-$observationStart).TotalMinutes,1),$stats.Activity,$system.CpuPct,$system.FreeMemoryPct) }
    } while ((Get-Date) -lt $deadline)

    $observedMinutes = [math]::Round(((Get-Date)-$observationStart).TotalMinutes,2)
    if ($observedMinutes -lt ($DurationMinutes - 0.2)) { throw "Step20 observation ended early." }

    $finalStats = Read-WorkerStats
    $minimumEvents = [math]::Max(5,[math]::Floor($DurationMinutes / 4))
    if ([int]$finalStats.Activity -lt $minimumEvents) { throw "Insufficient decision activity for Step20." }
    if ([int]$finalStats.Dry -ne [int]$finalStats.Activity) { throw "Not every decision cycle remained dry-run." }
    if ([int]$finalStats.Tracebacks -ne 0) { throw "Worker traceback count not zero." }

    $workerFinal = Get-WorkerSnapshot $workerPid
    $coreFinalRes = Get-ProcessSnapshot $corePid
    $bridgeFinalRes = Get-ProcessSnapshot $bridgePid
    $jarvisFinalRes = Get-ProcessSnapshot $jarvisPid
    Assert-ResourceGrowth "Worker" $workerBase $workerFinal
    Assert-ResourceGrowth "Core" $coreBase $coreFinalRes
    Assert-ResourceGrowth "Bridge" $bridgeBase $bridgeFinalRes
    Assert-ResourceGrowth "Jarvis" $jarvisBase $jarvisFinalRes

    $sorted = @($latencies | Sort-Object)
    if ($sorted.Count -lt 1) { throw "No latency evidence collected." }
    $p95Index = [math]::Min($sorted.Count-1,[math]::Ceiling($sorted.Count*0.95)-1)
    $p95Ms = [double]$sorted[$p95Index]
    if ($p95Ms -gt 5000) { throw "Local read-only HTTP p95 latency exceeded 5000ms: $p95Ms" }

    Stop-CertWorker
    if (@(Get-WorkerProcesses).Count -ne 0) { throw "Worker failed to stop after Step20." }

    Invoke-MT5Helper -StartEpoch $startEpoch

    Confirm-Safety
    if ((Get-FileHash $envFile -Algorithm SHA256).Hash.ToUpperInvariant() -ne $envHash) { throw "Production .env changed during Step20." }
    foreach ($f in $criticalFiles) {
        if ((Get-FileHash $f -Algorithm SHA256).Hash.ToUpperInvariant() -ne $sourceHashes[$f]) { throw "Critical source changed during Step20: $f" }
    }
    if ((Get-ListenerPid 8088) -ne $corePid -or (Get-ListenerPid 8090) -ne $bridgePid -or (Get-ListenerPid 8787) -ne $jarvisPid) { throw "Core/Bridge/Jarvis continuity failed at final gate." }
    if (-not (Get-JarvisObserveOnly)) { throw "Jarvis final mode is not OBSERVE_ONLY." }

    $finishedUtc = [DateTime]::UtcNow
    $resultLabel = if ($DiagnosticOnly) { "DIAGNOSTIC_PASS" } else { "PASS" }
    $summary = [ordered]@{
        build_marker=$buildMarker
        result=$resultLabel
        started_utc=$startedUtc.ToString('o')
        finished_utc=$finishedUtc.ToString('o')
        observed_minutes=$observedMinutes
        sample_seconds=$SampleSeconds
        decision_events=[int]$finalStats.Activity
        dry_run_events=[int]$finalStats.Dry
        tracebacks=[int]$finalStats.Tracebacks
        infra_probe_count=$infraProbeCount
        data_probe_count=$dataProbeCount
        local_http_p95_ms=[math]::Round($p95Ms,2)
        system_peak_cpu_pct=[math]::Round($peakCpu,2)
        system_min_free_memory_pct=[math]::Round($minFreeMemoryPct,2)
        zero_unintended_orders=$true
        production_env_changed=$false
        production_source_changed=$false
        live_money_authorized=$false
        metrics_csv=$metricsCsv
        worker_stdout=$workerStdout
        worker_stderr=$workerStderr
    }
    $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryFile -Encoding UTF8
    if (-not $DiagnosticOnly) { $summary | ConvertTo-Json -Depth 8 | Set-Content -Path $certFile -Encoding UTF8 }

    $certified = $true
    Write-Host ""
    Write-Host "===================================================="
    if ($DiagnosticOnly) { Write-Host " STEP 20 SOAK DIAGNOSTIC = PASS" } else { Write-Host " STEP 20 SOAK / ENDURANCE CERTIFICATION = PASS" }
    Write-Host "===================================================="
    Write-Host "STEP20_DURATION=PASS"
    Write-Host "STEP20_OBSERVED_MINUTES=$observedMinutes"
    Write-Host "STEP20_DECISION_ACTIVITY=PASS"
    Write-Host "STEP20_DECISION_EVENTS=$($finalStats.Activity)"
    Write-Host "STEP20_ALL_ACTIVITY_DRY_RUN=PASS"
    Write-Host "STEP20_TRACEBACKS=0"
    Write-Host "STEP20_INFRASTRUCTURE=PASS"
    Write-Host "STEP20_RESOURCE_STABILITY=PASS"
    Write-Host "STEP20_HTTP_P95_MS=$([math]::Round($p95Ms,2))"
    Write-Host "STEP20_SOURCE_IMMUTABILITY=PASS"
    Write-Host "STEP20_ENV_IMMUTABILITY=PASS"
    Write-Host "STEP20_ZERO_UNINTENDED_ORDERS=PASS"
    Write-Host "STEP20_CORE_CONTINUITY=PASS"
    Write-Host "STEP20_BRIDGE_CONTINUITY=PASS"
    Write-Host "STEP20_JARVIS_CONTINUITY=PASS"
    Write-Host "WORKER_FINAL=OFF"
    Write-Host "PRODUCTION_LIVE_TRADING=OFF"
    Write-Host "PRODUCTION_MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"
    Write-Host "LIVE_MONEY_AUTHORIZED=False"
    Write-Host "STEP20=$resultLabel"
    Write-Host "STEP20_SUMMARY=$summaryFile"
    Write-Host "STEP20_METRICS=$metricsCsv"
    Write-Host "===================================================="
}
catch {
    $failure = $_.Exception.Message
    Write-Host "STEP20_FAILURE=$failure"
    Write-Host "STEP20=FAIL"
    Write-Host "LIVE_MONEY_AUTHORIZED=False"
    throw
}
finally {
    Stop-CertWorker
    try { Confirm-Safety } catch { Write-Host "STEP20_FINAL_SAFETY_RECHECK=FAIL" }
    Write-Host "STEP20_WORKER_FINAL_OFF=$(@(Get-WorkerProcesses).Count -eq 0)"
    Write-Host "STEP20_PRODUCTION_ENV_MODIFIED_BY_SCRIPT=False"
}
