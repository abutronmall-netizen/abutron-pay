$ErrorActionPreference = "Stop"

$root = "C:\Abutron\TradingPlatformV4"
$jarvisRoot = "C:\Abutron\Jarvis"
$envFile = "$root\.env"
$jarvisEnv = "$jarvisRoot\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"
$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"
$symbol = "XAUUSD"
$magic = 400040
$certified = $false
$failureMessage = ""

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

function Get-MT5 {
    return @(Get-CimInstance Win32_Process | Where-Object { $_.Name -ieq "terminal64.exe" -and $_.ExecutablePath -ieq $mt5Path })
}

function Get-OwnerInfo {
    param([int]$PidValue)
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$PidValue" -ErrorAction Stop
    $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
    return @{ Process=$p; User=$o.User; Domain=$o.Domain; Owner="$($o.Domain)\$($o.User)" }
}

function Confirm-WorkerOff {
    $workers = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "abutron\.worker" })
    if ($workers.Count -ne 0) { throw "Trading worker unexpectedly running." }
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
    Confirm-WorkerOff
}

function Wait-MT5Count {
    param([int]$Expected,[int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $items = @(Get-MT5)
        if ($items.Count -eq $Expected) { return $true }
        if ($Expected -eq 1 -and $items.Count -gt 1) { return $false }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Ensure-OneMT5 {
    $items = @(Get-MT5)
    if ($items.Count -eq 1) { return $items[0] }

    Write-Host "MT5_NORMALIZATION_REQUIRED=True"
    Stop-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction SilentlyContinue | Out-Null

    foreach ($item in $items) {
        Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue
    }

    if (-not (Wait-MT5Count -Expected 0 -Seconds 30)) { throw "Unable to reach zero-MT5 normalization state." }

    Enable-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction Stop

    if (-not (Wait-MT5Count -Expected 1 -Seconds 120)) { throw "MT5 normalization failed to produce exactly one process." }

    $final = @(Get-MT5)
    if ($final.Count -ne 1) { throw "MT5 normalization final count is not one." }
    Write-Host "BASELINE_MT5_NORMALIZATION=PASS"
    return $final[0]
}

function Wait-BridgeHealthy {
    param([int]$Seconds)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        try {
            $h = Invoke-RestMethod -Uri "http://127.0.0.1:8090/health" -TimeoutSec 10
            $ok = ($h.status -eq "ok" -and $h.mt5_connected -eq $true -and $h.live_trading -eq $false -and $h.management_enabled -eq $false)
            if ($ok) { return $h }
        } catch {}
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Get-JarvisObserveOnly {
    $token = Get-EnvValue $jarvisEnv "JARVIS_API_TOKEN"
    if ([string]::IsNullOrWhiteSpace($token)) { throw "Jarvis API token unavailable." }
    $headers = @{ "X-Jarvis-Token" = $token }
    $h = Invoke-RestMethod -Uri "http://127.0.0.1:8787/v1/system/health" -Headers $headers -TimeoutSec 120
    $json = $h | ConvertTo-Json -Depth 15 -Compress
    return (($json -match '(?i)"mode"\s*:\s*"OBSERVE_ONLY"') -or ($json -match '(?i)"observe_only"\s*:\s*true'))
}

function Restore-MT5Safe {
    Enable-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction SilentlyContinue | Out-Null
    $items = @(Get-MT5)
    if ($items.Count -eq 0) {
        Start-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction SilentlyContinue
        $null = Wait-MT5Count -Expected 1 -Seconds 120
    } elseif ($items.Count -gt 1) {
        $null = Ensure-OneMT5
    }
    return @(Get-MT5)
}

try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " ABUTRON - STEP 13D FINAL CERTIFICATION"
    Write-Host " MT5 DISCONNECT / FAIL-CLOSED / RECOVERY"
    Write-Host "===================================================="

    Confirm-Safety
    Write-Host "SAFETY_GATE=PASS"
    Write-Host "WORKER=OFF"

    $coreTask = Get-ScheduledTask -TaskName "Abutron-Core" -ErrorAction Stop
    $bridgeTask = Get-ScheduledTask -TaskName "Abutron-MT5Bridge" -ErrorAction Stop
    $mt5Task = Get-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction Stop

    if ($coreTask.Principal.UserId -ne "SYSTEM") { throw "Core task identity mismatch." }
    if ($bridgeTask.Principal.UserId -notmatch "Administrator") { throw "Bridge task identity mismatch." }
    if ($mt5Task.Principal.UserId -notmatch "Administrator") { throw "MT5 task identity mismatch." }
    Write-Host "TASK_IDENTITY_GATE=PASS"

    $mt5Baseline = Ensure-OneMT5
    $mt5OldPid = [int]$mt5Baseline.ProcessId
    $mt5Session = [int]$mt5Baseline.SessionId
    $mt5Owner = Get-OwnerInfo $mt5OldPid
    if ($mt5Owner.User -ine "Administrator") { throw "MT5 baseline owner is not Administrator." }

    $corePid = Get-ListenerPid 8088
    $bridgePid = Get-ListenerPid 8090
    $jarvisPid = Get-ListenerPid 8787
    if (-not $corePid) { throw "Core listener missing." }
    if (-not $bridgePid) { throw "Bridge listener missing." }
    if (-not $jarvisPid) { throw "Jarvis listener missing." }

    $coreOwner = Get-OwnerInfo $corePid
    $bridgeOwner = Get-OwnerInfo $bridgePid
    if ($coreOwner.User -ine "SYSTEM") { throw "Core is not SYSTEM-owned." }
    if ($bridgeOwner.User -ine "Administrator") { throw "Bridge is not Administrator-owned." }
    if ([int]$bridgeOwner.Process.SessionId -ne $mt5Session) { throw "Bridge and MT5 session mismatch." }

    $coreHealth = Invoke-RestMethod -Uri "http://127.0.0.1:8088/health" -TimeoutSec 60
    if ($coreHealth.status -ne "ok") { throw "Core unhealthy." }
    if ($coreHealth.kronos_loaded -ne $true) { throw "Kronos not loaded." }
    if ($coreHealth.execution_enabled -ne $false) { throw "Core execution unexpectedly enabled." }

    $bridgeHealth = Wait-BridgeHealthy -Seconds 120
    if (-not $bridgeHealth) { throw "Bridge baseline health failed." }

    if (-not (Get-JarvisObserveOnly)) { throw "Jarvis is not OBSERVE_ONLY." }

    Write-Host "BASELINE=PASS"
    Write-Host "CORE_PID=$corePid"
    Write-Host "BRIDGE_PID=$bridgePid"
    Write-Host "JARVIS_PID=$jarvisPid"
    Write-Host "MT5_OLD_PID=$mt5OldPid"
    Write-Host "MT5_SESSION=$mt5Session"
    Write-Host "JARVIS_OBSERVE_ONLY=PASS"

    $testStartUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    Write-Host ""
    Write-Host "--- CONTROLLED MT5 OUTAGE ---"
    Stop-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction SilentlyContinue
    Disable-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction Stop | Out-Null
    Stop-Process -Id $mt5OldPid -Force -ErrorAction Stop

    if (-not (Wait-MT5Count -Expected 0 -Seconds 30)) { throw "Could not establish zero-process MT5 outage." }

    Write-Host "CONTROLLED_MT5_DISCONNECT=PASS"
    Write-Host "OUTAGE_WINDOW_CONFIRMED=PASS"
    Start-Sleep -Seconds 5

    if (@(Get-MT5).Count -ne 0) { throw "MT5 returned before outage probe." }
    Confirm-Safety
    if ((Get-ListenerPid 8088) -ne $corePid) { throw "Core restarted during MT5 outage." }
    if ((Get-ListenerPid 8787) -ne $jarvisPid) { throw "Jarvis restarted during MT5 outage." }

    Write-Host "FAIL_CLOSED_WINDOW_HELD=PASS"
    Write-Host "ORDER_ENDPOINT_CALLED=False"
    Write-Host "MUTATING_ENDPOINTS_CALLED=False"

    $probeReturned = $false
    $probeConnected = $false
    try {
        $outageHealth = Invoke-RestMethod -Uri "http://127.0.0.1:8090/health" -TimeoutSec 20
        $probeReturned = $true
        $probeConnected = [bool]$outageHealth.mt5_connected
    } catch {
        Write-Host "BRIDGE_OUTAGE_HTTP=UNAVAILABLE"
    }

    Start-Sleep -Seconds 2
    $afterProbe = @(Get-MT5)

    if ($afterProbe.Count -eq 0) {
        if ($probeReturned -and $probeConnected) { throw "Bridge reported MT5 connected while no terminal existed." }
        $recoveryPath = "MT5_SCHEDULED_TASK"
        Write-Host "BRIDGE_OUTAGE_DETECTION=DISCONNECTED"
    } elseif ($afterProbe.Count -eq 1) {
        $recoveryPath = "BRIDGE_AUTO_REINITIALIZE"
        Write-Host "BRIDGE_OUTAGE_DETECTION=AUTO_RECOVERY"
    } else {
        throw "Bridge outage probe created duplicate MT5 terminals."
    }

    Write-Host "FAIL_CLOSED_DURING_OUTAGE=PASS"

    Enable-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction Stop | Out-Null
    $current = @(Get-MT5)
    if ($current.Count -eq 0) { Start-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction Stop }
    if (-not (Wait-MT5Count -Expected 1 -Seconds 120)) { throw "MT5 recovery did not produce exactly one terminal." }

    $mt5Recovered = @(Get-MT5)
    if ($mt5Recovered.Count -ne 1) { throw "Recovered MT5 process count invalid." }

    $mt5NewPid = [int]$mt5Recovered[0].ProcessId
    $mt5NewSession = [int]$mt5Recovered[0].SessionId
    $mt5NewOwner = Get-OwnerInfo $mt5NewPid
    if ($mt5NewOwner.User -ine "Administrator") { throw "Recovered MT5 owner mismatch." }
    if ($mt5NewSession -ne $mt5Session) { throw "Recovered MT5 session mismatch." }
    if ($mt5NewPid -eq $mt5OldPid) { throw "MT5 PID did not change after controlled restart." }

    Write-Host "MT5_RECOVERY=PASS"
    Write-Host "MT5_RECOVERY_PATH=$recoveryPath"
    Write-Host "MT5_NEW_PID=$mt5NewPid"

    $bridgeRecovered = Wait-BridgeHealthy -Seconds 180
    if (-not $bridgeRecovered) { throw "Bridge failed to reconnect to MT5." }

    $bridgePidAfter = Get-ListenerPid 8090
    if (-not $bridgePidAfter) { throw "Bridge listener missing after recovery." }

    $bridgeOwnerAfter = Get-OwnerInfo $bridgePidAfter
    if ($bridgeOwnerAfter.User -ine "Administrator") { throw "Bridge owner changed." }
    if ([int]$bridgeOwnerAfter.Process.SessionId -ne $mt5NewSession) { throw "Bridge and recovered MT5 session mismatch." }

    Write-Host "BRIDGE_RECONNECT=PASS"
    Write-Host "BRIDGE_MT5_SESSION_MATCH=PASS"

    $expectedServer = Get-EnvValue $envFile "MT5_EXPECTED_SERVER"
    if ([string]::IsNullOrWhiteSpace($expectedServer)) { throw "MT5_EXPECTED_SERVER missing." }

    $pyCode = @(
        'import sys,time'
        'from datetime import datetime, timezone'
        'import MetaTrader5 as mt5'
        'path=sys.argv[1]'
        'expected=sys.argv[2]'
        'start_epoch=int(sys.argv[3])'
        'symbol=sys.argv[4]'
        'magic=int(sys.argv[5])'
        'ok=mt5.initialize(path=path)'
        'print("PROBE_INIT="+str(bool(ok)))'
        'if not ok: raise SystemExit(2)'
        'ti=mt5.terminal_info()'
        'ai=mt5.account_info()'
        'connected=bool(ti and ti.connected and ai)'
        'server_match=bool(ai and ai.server==expected)'
        'print("PROBE_CONNECTED="+str(connected))'
        'print("PROBE_SERVER_MATCH="+str(server_match))'
        'selected=mt5.symbol_select(symbol,True)'
        'print("PROBE_SYMBOL_SELECTED="+str(bool(selected)))'
        'tick=mt5.symbol_info_tick(symbol)'
        'print("PROBE_TICK="+str(tick is not None))'
        'tick_epoch=(float(tick.time_msc)/1000.0 if tick is not None and getattr(tick,"time_msc",0) else float(tick.time) if tick is not None else 0.0)'
        'tick_age=(max(0.0,time.time()-tick_epoch) if tick is not None else 999999.0)'
        'print("PROBE_TICK_AGE_SECONDS="+f"{tick_age:.3f}")'
        'deals=mt5.history_deals_get(datetime.fromtimestamp(start_epoch,tz=timezone.utc),datetime.now(timezone.utc))'
        'print("PROBE_HISTORY_OK="+str(deals is not None))'
        'count=sum(1 for d in deals if getattr(d,"magic",None)==magic) if deals is not None else -1'
        'print("ABUTRON_MAGIC_DEALS="+str(count))'
        'mt5.shutdown()'
    ) -join "`n"

    $probeOutput = @(& $pythonExe -c $pyCode $mt5Path $expectedServer $testStartUnix $symbol $magic 2>&1)
    $probeExit = $LASTEXITCODE
    foreach ($line in $probeOutput) { Write-Host $line }
    if ($probeExit -ne 0) { throw "Read-only MT5 probe failed with exit code $probeExit." }

    $probeValues = @{}
    foreach ($line in $probeOutput) {
        $text = [string]$line
        if ($text -match '^([A-Z0-9_]+)=(.*)$') { $probeValues[$matches[1]] = $matches[2] }
    }

    if ($probeValues["PROBE_INIT"] -ne "True") { throw "MT5 probe initialization failed." }
    if ($probeValues["PROBE_CONNECTED"] -ne "True") { throw "Recovered MT5 is not connected." }
    if ($probeValues["PROBE_SERVER_MATCH"] -ne "True") { throw "Recovered MT5 server mismatch." }
    if ($probeValues["PROBE_SYMBOL_SELECTED"] -ne "True") { throw "XAUUSD selection failed." }
    if ($probeValues["PROBE_TICK"] -ne "True") { throw "XAUUSD tick unavailable." }
    if ($probeValues["PROBE_HISTORY_OK"] -ne "True") { throw "MT5 deal-history probe failed." }

    $tickAge = [double]$probeValues["PROBE_TICK_AGE_SECONDS"]
    if ($tickAge -gt 300.0) { throw "Recovered XAUUSD tick is stale: $tickAge seconds." }

    $magicDeals = [int]$probeValues["ABUTRON_MAGIC_DEALS"]
    if ($magicDeals -ne 0) { throw "Abutron-magic deals appeared during Step 13D." }

    Write-Host "FRESH_MARKET_DATA_AFTER_RECOVERY=PASS"
    Write-Host "NO_ABUTRON_MAGIC_DEALS=PASS"

    if ((Get-ListenerPid 8088) -ne $corePid) { throw "Core PID changed during Step 13D." }
    if ((Get-ListenerPid 8787) -ne $jarvisPid) { throw "Jarvis PID changed during Step 13D." }

    $coreFinal = Invoke-RestMethod -Uri "http://127.0.0.1:8088/health" -TimeoutSec 60
    if ($coreFinal.status -ne "ok") { throw "Core unhealthy after recovery." }
    if ($coreFinal.kronos_loaded -ne $true) { throw "Kronos unloaded." }
    if ($coreFinal.execution_enabled -ne $false) { throw "Core execution changed." }

    $coreFinalOwner = Get-OwnerInfo $corePid
    if ($coreFinalOwner.User -ine "SYSTEM") { throw "Core lost SYSTEM ownership." }
    if (-not (Get-JarvisObserveOnly)) { throw "Jarvis left OBSERVE_ONLY." }

    Confirm-Safety
    if (@(Get-MT5).Count -ne 1) { throw "Final MT5 process count is not one." }

    $mt5TaskFinal = Get-ScheduledTask -TaskName "Abutron-MT5" -ErrorAction Stop
    if ($mt5TaskFinal.State -eq "Disabled") { throw "MT5 task remained disabled." }

    $certified = $true
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    if (-not $certified) {
        try {
            $restored = @(Restore-MT5Safe)
            if ($restored.Count -eq 1) {
                Write-Host "EMERGENCY_MT5_RECOVERY=PASS"
                Write-Host "EMERGENCY_MT5_PID=$($restored[0].ProcessId)"
            } else {
                Write-Host "EMERGENCY_MT5_RECOVERY=FAILED"
            }
        } catch {
            Write-Host "EMERGENCY_MT5_RECOVERY_ERROR=$($_.Exception.Message)"
        }

        try {
            Confirm-Safety
            Write-Host "FAILURE_STATE_SAFETY=PASS"
            Write-Host "WORKER=OFF"
            Write-Host "LIVE_TRADING=OFF"
            Write-Host "MANAGEMENT=OFF"
            Write-Host "ABUTRON_EXECUTION=OFF"
        } catch {
            Write-Host "FAILURE_STATE_SAFETY=CHECK_REQUIRED"
        }
    }
}

if (-not $certified) {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 13D = NOT CERTIFIED"
    Write-Host "===================================================="
    Write-Host "FAILURE=$failureMessage"
    exit 1
}

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 13D = PASS"
Write-Host "===================================================="
Write-Host "CONTROLLED_MT5_DISCONNECT=PASS"
Write-Host "OUTAGE_WINDOW_CONFIRMED=PASS"
Write-Host "FAIL_CLOSED_WINDOW_HELD=PASS"
Write-Host "FAIL_CLOSED_DURING_OUTAGE=PASS"
Write-Host "MT5_RECOVERY=PASS"
Write-Host "MT5_RECOVERY_PATH=$recoveryPath"
Write-Host "BRIDGE_RECONNECT=PASS"
Write-Host "BRIDGE_MT5_SESSION_MATCH=PASS"
Write-Host "FRESH_MARKET_DATA_AFTER_RECOVERY=PASS"
Write-Host "NO_ABUTRON_MAGIC_DEALS=PASS"
Write-Host "CORE_PID_CONTINUITY=PASS"
Write-Host "CORE_SYSTEM_OWNERSHIP=PASS"
Write-Host "KRONOS_LOADED=True"
Write-Host "JARVIS_PID_CONTINUITY=PASS"
Write-Host "JARVIS_MODE=OBSERVE_ONLY"
Write-Host "MUTATING_ENDPOINTS_CALLED=False"
Write-Host "ORDER_ENDPOINT_CALLED=False"
Write-Host "WORKER=OFF"
Write-Host "LIVE_TRADING=OFF"
Write-Host "MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "NO_TRADES_SENT"
Write-Host "===================================================="
exit 0
