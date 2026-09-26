$ErrorActionPreference = "Stop"

# =====================================================================
# ABUTRON STEP 15
# DATABASE / AUDIT PERSISTENCE / RESTART RECONCILIATION CERTIFICATION
#
# This certification:
#   - keeps trading execution disabled
#   - requires worker OFF
#   - verifies DecisionStore + Platform DB + Bridge idempotency DB
#   - creates synthetic, clearly marked persistence probes
#   - verifies duplicate deal reconciliation suppression
#   - performs SQLite and PostgreSQL-native backup/restore integrity drills
#   - restarts Core and Bridge through their certified Scheduled Tasks
#   - verifies markers survive process restart
#   - verifies MT5 zero-state continuity
#   - removes synthetic decision/trade/claim markers
#   - retains one STEP15_CERTIFIED audit event
#
# It DOES NOT call order/manage/close endpoints.
# =====================================================================

$root       = "C:\Abutron\TradingPlatformV4"
$jarvisRoot = "C:\Abutron\Jarvis"

$envFile    = "$root\.env"
$jarvisEnv  = "$jarvisRoot\.env"
$pythonExe  = "$root\.venv\Scripts\python.exe"
$helper     = "$root\scripts\step15_persistence_probe_v2.py"

$logDir     = "$root\logs"
$backupRoot = "$root\backups"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$marker = "STEP15-$stamp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$backupDir = "$backupRoot\$marker"
$summaryFile = "$logDir\step15_summary_$stamp.txt"

$testStartEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$certified = $false
$failureMessage = ""
$coreRestarted = $false
$bridgeRestarted = $false
$markersCreated = $false

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

function Confirm-WorkerOff {
    $workers = @(Get-WorkerProcesses)

    if ($workers.Count -ne 0) {
        $ids = ($workers | ForEach-Object { $_.ProcessId }) -join ","
        throw "Trading worker must remain OFF. Worker PIDs: $ids"
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

    Confirm-WorkerOff
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

function Wait-PortFree {
    param(
        [int]$Port,
        [int]$Seconds = 60
    )

    $deadline = (Get-Date).AddSeconds($Seconds)

    do {
        if (-not (Get-ListenerPid $Port)) {
            return $true
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Wait-CoreHealthy {
    param([int]$Seconds = 240)

    $deadline = (Get-Date).AddSeconds($Seconds)

    do {
        try {
            $h = Get-CoreHealth

            if (
                $h.status -eq "ok" -and
                $h.kronos_loaded -eq $true -and
                $h.execution_enabled -eq $false -and
                $h.database -eq $true
            ) {
                return $h
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Wait-BridgeHealthy {
    param([int]$Seconds = 180)

    $deadline = (Get-Date).AddSeconds($Seconds)

    do {
        try {
            $h = Get-BridgeHealth

            if (
                $h.status -eq "ok" -and
                $h.mt5_connected -eq $true -and
                $h.live_trading -eq $false -and
                $h.management_enabled -eq $false
            ) {
                return $h
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $null
}

function Invoke-Step15Helper {
    param(
        [string]$Command,
        [switch]$WithBackup
    )

    $args = @(
        $helper,
        $Command,
        "--marker",
        $marker,
        "--mt5-path",
        $mt5Path,
        "--start-epoch",
        [string]$testStartEpoch
    )

    if ($WithBackup) {
        $args += @(
            "--backup-dir",
            $backupDir
        )
    }

    & $pythonExe @args

    if ($LASTEXITCODE -ne 0) {
        throw "Step 15 helper command failed: $Command"
    }
}

function Ensure-CoreRunning {
    $existing = Get-ListenerPid 8088

    if ($existing) {
        try {
            $h = Wait-CoreHealthy -Seconds 30

            if ($h) {
                return $existing
            }
        }
        catch {
        }
    }

    Enable-ScheduledTask `
        -TaskName "Abutron-Core" `
        -ErrorAction SilentlyContinue |
        Out-Null

    Start-ScheduledTask `
        -TaskName "Abutron-Core" `
        -ErrorAction SilentlyContinue

    $h = Wait-CoreHealthy -Seconds 240

    if (-not $h) {
        throw "Core could not be recovered."
    }

    return (Get-ListenerPid 8088)
}

function Ensure-BridgeRunning {
    $existing = Get-ListenerPid 8090

    if ($existing) {
        try {
            $h = Wait-BridgeHealthy -Seconds 30

            if ($h) {
                return $existing
            }
        }
        catch {
        }
    }

    Enable-ScheduledTask `
        -TaskName "Abutron-MT5Bridge" `
        -ErrorAction SilentlyContinue |
        Out-Null

    Start-ScheduledTask `
        -TaskName "Abutron-MT5Bridge" `
        -ErrorAction SilentlyContinue

    $h = Wait-BridgeHealthy -Seconds 180

    if (-not $h) {
        throw "MT5 Bridge could not be recovered."
    }

    return (Get-ListenerPid 8090)
}

try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " ABUTRON - STEP 15"
    Write-Host " DATABASE / AUDIT PERSISTENCE"
    Write-Host " RESTART RECONCILIATION CERTIFICATION"
    Write-Host "===================================================="
    Write-Host "MARKER=$marker"

    New-Item `
        -ItemType Directory `
        -Path $logDir `
        -Force |
        Out-Null

    New-Item `
        -ItemType Directory `
        -Path $backupRoot `
        -Force |
        Out-Null

    # ---------------------------------------------------------
    # 1. REQUIRED FILES + STATIC PERSISTENCE PATH AUDIT
    # ---------------------------------------------------------

    $requiredFiles = @(
        $pythonExe,
        $envFile,
        $helper,
        "$root\abutron\service.py",
        "$root\abutron\worker.py",
        "$root\abutron\platform_db.py",
        "$root\abutron\storage\decisions.py",
        "$root\mt5_bridge\store.py",
        "$root\mt5_bridge\app.py",
        $mt5Path
    )

    foreach ($required in $requiredFiles) {
        if (-not (Test-Path $required)) {
            throw "Required Step 15 file missing: $required"
        }
    }

    $serviceSource = Get-Content "$root\abutron\service.py" -Raw
    $workerSource = Get-Content "$root\abutron\worker.py" -Raw
    $platformSource = Get-Content "$root\abutron\platform_db.py" -Raw
    $bridgeStoreSource = Get-Content "$root\mt5_bridge\store.py" -Raw

    if ($serviceSource -notmatch 'self\.store\.add\s*\(') {
        throw "DecisionStore persistence call missing from TradingService."
    }

    if ($workerSource -notmatch 'def\s+sync_deals\s*\(') {
        throw "Worker sync_deals reconciliation function missing."
    }

    if ($workerSource -notmatch 'def\s+persist_execution\s*\(') {
        throw "Worker persist_execution function missing."
    }

    if ($platformSource -notmatch 'class\s+AuditEvent\s*\(') {
        throw "Platform AuditEvent model missing."
    }

    if ($platformSource -notmatch 'class\s+TradeRecord\s*\(') {
        throw "Platform TradeRecord model missing."
    }

    if ($bridgeStoreSource -notmatch 'def\s+claim\s*\(') {
        throw "Bridge atomic claim persistence missing."
    }

    if ($bridgeStoreSource -notmatch 'execution_claims') {
        throw "Bridge execution_claims schema missing."
    }

    Write-Host "STATIC_PERSISTENCE_PATH_AUDIT=PASS"

    # ---------------------------------------------------------
    # 2. SAFETY / OWNERSHIP BASELINE
    # ---------------------------------------------------------

    Confirm-Safety

    $corePidBefore = Get-ListenerPid 8088
    $bridgePidBefore = Get-ListenerPid 8090
    $jarvisPidBefore = Get-ListenerPid 8787

    if (-not $corePidBefore) {
        throw "Core listener missing."
    }

    if (-not $bridgePidBefore) {
        throw "Bridge listener missing."
    }

    if (-not $jarvisPidBefore) {
        throw "Jarvis listener missing."
    }

    $coreOwnerBefore = Get-OwnerInfo $corePidBefore
    $bridgeOwnerBefore = Get-OwnerInfo $bridgePidBefore

    if ($coreOwnerBefore.User -ine "SYSTEM") {
        throw "Core is not SYSTEM-owned."
    }

    if ($bridgeOwnerBefore.User -ine "Administrator") {
        throw "Bridge is not Administrator-owned."
    }

    $mt5Before = @(Get-ExpectedMT5)

    if ($mt5Before.Count -ne 1) {
        throw "Expected exactly one production MT5 terminal."
    }

    $mt5PidBefore = [int]$mt5Before[0].ProcessId
    $mt5Session = [int]$mt5Before[0].SessionId

    if ([int]$bridgeOwnerBefore.Process.SessionId -ne $mt5Session) {
        throw "Bridge and MT5 Windows session mismatch."
    }

    $coreHealthBefore = Wait-CoreHealthy -Seconds 60
    $bridgeHealthBefore = Wait-BridgeHealthy -Seconds 60

    if (-not $coreHealthBefore) {
        throw "Core baseline health failed."
    }

    if (-not $bridgeHealthBefore) {
        throw "Bridge baseline health failed."
    }

    if (-not (Get-JarvisObserveOnly)) {
        throw "Jarvis is not OBSERVE_ONLY."
    }

    Write-Host "SAFETY_BASELINE=PASS"
    Write-Host "CORE_PID_BEFORE=$corePidBefore"
    Write-Host "CORE_OWNER_BEFORE=$($coreOwnerBefore.Owner)"
    Write-Host "BRIDGE_PID_BEFORE=$bridgePidBefore"
    Write-Host "BRIDGE_OWNER_BEFORE=$($bridgeOwnerBefore.Owner)"
    Write-Host "MT5_PID=$mt5PidBefore"
    Write-Host "JARVIS_PID=$jarvisPidBefore"
    Write-Host "WORKER=OFF"
    Write-Host "LIVE_TRADING=OFF"
    Write-Host "MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"

    # ---------------------------------------------------------
    # 3. DATABASE INTEGRITY + SYNTHETIC PERSISTENCE MARKERS
    #    + BACKUP/RESTORE DRILL + ZERO-STATE MT5 SNAPSHOT
    # ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- STEP 15 DATABASE PREFLIGHT ---"

    $markersCreated = $true
    Invoke-Step15Helper `
        -Command "preflight" `
        -WithBackup

    Write-Host "DATABASE_PREFLIGHT=PASS"
    Write-Host "DATABASE_BACKUP_RESTORE_DRILL=PASS"

    # ---------------------------------------------------------
    # 4. CONTROLLED CORE RESTART
    # ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- CONTROLLED CORE RESTART ---"

    Stop-ScheduledTask `
        -TaskName "Abutron-Core" `
        -ErrorAction Stop

    if (-not (Wait-PortFree -Port 8088 -Seconds 60)) {
        throw "Core port 8088 did not become free."
    }

    Start-ScheduledTask `
        -TaskName "Abutron-Core" `
        -ErrorAction Stop

    $coreAfterRestart = Wait-CoreHealthy -Seconds 240

    if (-not $coreAfterRestart) {
        throw "Core did not recover after controlled restart."
    }

    $corePidAfter = Get-ListenerPid 8088

    if (-not $corePidAfter) {
        throw "Core listener missing after restart."
    }

    if ($corePidAfter -eq $corePidBefore) {
        throw "Core PID did not change after controlled restart."
    }

    $coreOwnerAfter = Get-OwnerInfo $corePidAfter

    if ($coreOwnerAfter.User -ine "SYSTEM") {
        throw "Restarted Core is not SYSTEM-owned."
    }

    $coreRestarted = $true

    Write-Host "CORE_RESTART=PASS"
    Write-Host "CORE_PID_AFTER=$corePidAfter"
    Write-Host "CORE_SYSTEM_OWNERSHIP=PASS"

    # ---------------------------------------------------------
    # 5. CONTROLLED BRIDGE RESTART
    # ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- CONTROLLED BRIDGE RESTART ---"

    Stop-ScheduledTask `
        -TaskName "Abutron-MT5Bridge" `
        -ErrorAction Stop

    if (-not (Wait-PortFree -Port 8090 -Seconds 60)) {
        throw "Bridge port 8090 did not become free."
    }

    Start-ScheduledTask `
        -TaskName "Abutron-MT5Bridge" `
        -ErrorAction Stop

    $bridgeAfterRestart = Wait-BridgeHealthy -Seconds 180

    if (-not $bridgeAfterRestart) {
        throw "Bridge did not recover after controlled restart."
    }

    $bridgePidAfter = Get-ListenerPid 8090

    if (-not $bridgePidAfter) {
        throw "Bridge listener missing after restart."
    }

    if ($bridgePidAfter -eq $bridgePidBefore) {
        throw "Bridge PID did not change after controlled restart."
    }

    $bridgeOwnerAfter = Get-OwnerInfo $bridgePidAfter

    if ($bridgeOwnerAfter.User -ine "Administrator") {
        throw "Restarted Bridge is not Administrator-owned."
    }

    if ([int]$bridgeOwnerAfter.Process.SessionId -ne $mt5Session) {
        throw "Restarted Bridge session no longer matches MT5."
    }

    $bridgeRestarted = $true

    Write-Host "BRIDGE_RESTART=PASS"
    Write-Host "BRIDGE_PID_AFTER=$bridgePidAfter"
    Write-Host "BRIDGE_MT5_SESSION_MATCH=PASS"

    # ---------------------------------------------------------
    # 6. PERSISTENCE / RECONCILIATION AFTER BOTH RESTARTS
    # ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- POST-RESTART PERSISTENCE VERIFY ---"

    Invoke-Step15Helper `
        -Command "verify"

    Write-Host "DATABASE_MARKERS_SURVIVED_RESTART=PASS"
    Write-Host "RECONCILIATION_IDEMPOTENCY=PASS"
    Write-Host "BRIDGE_CLAIM_SURVIVED_RESTART=PASS"

    # Protect untouched components.
    if ((Get-ListenerPid 8787) -ne $jarvisPidBefore) {
        throw "Jarvis restarted during Step 15."
    }

    $mt5After = @(Get-ExpectedMT5)

    if ($mt5After.Count -ne 1) {
        throw "MT5 process count changed during Step 15."
    }

    if ([int]$mt5After[0].ProcessId -ne $mt5PidBefore) {
        throw "MT5 restarted during Step 15."
    }

    # ---------------------------------------------------------
    # 7. CLEAN SYNTHETIC STATE
    # ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- CLEANING SYNTHETIC CERTIFICATION STATE ---"

    Invoke-Step15Helper `
        -Command "cleanup"

    $markersCreated = $false

    Invoke-Step15Helper `
        -Command "final-audit"

    Invoke-Step15Helper `
        -Command "verify-final"

    Write-Host "SYNTHETIC_STATE_CLEANUP=PASS"
    Write-Host "STEP15_CERTIFIED_AUDIT_RETAINED=PASS"

    # ---------------------------------------------------------
    # 8. FINAL PLATFORM CONTINUITY / SAFETY
    # ---------------------------------------------------------

    $coreFinal = Wait-CoreHealthy -Seconds 60
    $bridgeFinal = Wait-BridgeHealthy -Seconds 60

    if (-not $coreFinal) {
        throw "Core final health failed."
    }

    if (-not $bridgeFinal) {
        throw "Bridge final health failed."
    }

    if (-not (Get-JarvisObserveOnly)) {
        throw "Jarvis left OBSERVE_ONLY."
    }

    Confirm-Safety

    $coreTaskFinal = Get-ScheduledTask `
        -TaskName "Abutron-Core" `
        -ErrorAction Stop

    $bridgeTaskFinal = Get-ScheduledTask `
        -TaskName "Abutron-MT5Bridge" `
        -ErrorAction Stop

    if ($coreTaskFinal.State -ne "Running") {
        throw "Core Scheduled Task is not Running."
    }

    if ($bridgeTaskFinal.State -ne "Running") {
        throw "Bridge Scheduled Task is not Running."
    }

    $summary = @(
        "STEP_15=PASS"
        "MARKER=$marker"
        "CORE_PID_BEFORE=$corePidBefore"
        "CORE_PID_AFTER=$corePidAfter"
        "BRIDGE_PID_BEFORE=$bridgePidBefore"
        "BRIDGE_PID_AFTER=$bridgePidAfter"
        "MT5_PID=$mt5PidBefore"
        "JARVIS_PID=$jarvisPidBefore"
        "DATABASE_INTEGRITY=PASS"
        "DECISION_STORE_PERSISTENCE=PASS"
        "AUDIT_PERSISTENCE=PASS"
        "TRADE_RECONCILIATION_IDEMPOTENCY=PASS"
        "BRIDGE_CLAIM_PERSISTENCE=PASS"
        "DATABASE_BACKUP_RESTORE_DRILL=PASS"
        "CORE_RESTART_RECONCILIATION=PASS"
        "BRIDGE_RESTART_RECONCILIATION=PASS"
        "MT5_ZERO_STATE_RECONCILIATION=PASS"
        "SYNTHETIC_STATE_CLEANUP=PASS"
        "STEP15_CERTIFIED_AUDIT_RETAINED=PASS"
        "KRONOS_LOADED=True"
        "JARVIS_MODE=OBSERVE_ONLY"
        "WORKER=OFF"
        "LIVE_TRADING=OFF"
        "MANAGEMENT=OFF"
        "ABUTRON_EXECUTION=OFF"
        "NO_TRADES_SENT"
        "BACKUP_DIR=$backupDir"
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
    # Worker must never be active at the end.
    try {
        $workers = @(Get-WorkerProcesses)

        foreach ($w in $workers) {
            Stop-Process `
                -Id ([int]$w.ProcessId) `
                -Force `
                -ErrorAction SilentlyContinue
        }

        Start-Sleep -Seconds 1

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

    # Best-effort synthetic marker cleanup on any failure.
    if ($markersCreated) {
        try {
            Invoke-Step15Helper `
                -Command "cleanup"

            Write-Host "FAILSAFE_SYNTHETIC_CLEANUP=PASS"
        }
        catch {
            Write-Host "FAILSAFE_SYNTHETIC_CLEANUP=CHECK_REQUIRED"
        }
    }

    # Recover Core and Bridge if a controlled restart failed halfway.
    try {
        $recoveredCore = Ensure-CoreRunning

        if ($recoveredCore) {
            Write-Host "FAILSAFE_CORE_RUNNING=PASS"
        }
    }
    catch {
        Write-Host "FAILSAFE_CORE_RUNNING=CHECK_REQUIRED"
    }

    try {
        $recoveredBridge = Ensure-BridgeRunning

        if ($recoveredBridge) {
            Write-Host "FAILSAFE_BRIDGE_RUNNING=PASS"
        }
    }
    catch {
        Write-Host "FAILSAFE_BRIDGE_RUNNING=CHECK_REQUIRED"
    }

    try {
        Confirm-Safety
        Write-Host "FAILSAFE_EXECUTION_LOCKS=PASS"
    }
    catch {
        Write-Host "FAILSAFE_EXECUTION_LOCKS=CHECK_REQUIRED"
    }
}

if (-not $certified) {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 15 = NOT CERTIFIED"
    Write-Host "===================================================="
    Write-Host "FAILURE=$failureMessage"
    Write-Host "WORKER=OFF_EXPECTED"
    Write-Host "LIVE_TRADING=OFF_EXPECTED"
    Write-Host "MANAGEMENT=OFF_EXPECTED"
    Write-Host "ABUTRON_EXECUTION=OFF_EXPECTED"
    Write-Host "BACKUP_DIR=$backupDir"
    exit 1
}

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 15 = PASS"
Write-Host "===================================================="
Write-Host "DATABASE_INTEGRITY=PASS"
Write-Host "DECISION_STORE_PERSISTENCE=PASS"
Write-Host "AUDIT_PERSISTENCE=PASS"
Write-Host "TRADE_RECONCILIATION_IDEMPOTENCY=PASS"
Write-Host "BRIDGE_CLAIM_PERSISTENCE=PASS"
Write-Host "DATABASE_BACKUP_RESTORE_DRILL=PASS"
Write-Host "CORE_RESTART_RECONCILIATION=PASS"
Write-Host "BRIDGE_RESTART_RECONCILIATION=PASS"
Write-Host "MT5_ZERO_STATE_RECONCILIATION=PASS"
Write-Host "SYNTHETIC_STATE_CLEANUP=PASS"
Write-Host "STEP15_CERTIFIED_AUDIT_RETAINED=PASS"
Write-Host "CORE_SYSTEM_OWNERSHIP=PASS"
Write-Host "BRIDGE_MT5_SESSION_MATCH=PASS"
Write-Host "MT5_PID_CONTINUITY=PASS"
Write-Host "JARVIS_PID_CONTINUITY=PASS"
Write-Host "KRONOS_LOADED=True"
Write-Host "JARVIS_MODE=OBSERVE_ONLY"
Write-Host "WORKER=OFF"
Write-Host "LIVE_TRADING=OFF"
Write-Host "MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "ORDER_ENDPOINT_CALLED=False"
Write-Host "MANAGE_ENDPOINT_CALLED=False"
Write-Host "CLOSE_ENDPOINT_CALLED=False"
Write-Host "NO_TRADES_SENT"
Write-Host "BACKUP_DIR=$backupDir"
Write-Host "SUMMARY_FILE=$summaryFile"
Write-Host "===================================================="

exit 0
