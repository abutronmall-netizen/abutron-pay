$ErrorActionPreference = "Stop"

$root      = "C:\Abutron\TradingPlatformV4"
$envFile   = "$root\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"
$appFile   = "$root\mt5_bridge\app.py"
$patcher   = "$root\scripts\step18_manage_hardening_patch.py"
$taskName  = "Abutron-MT5Bridge"
$mt5Path   = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$logDir     = "$root\logs"
$stamp      = Get-Date -Format "yyyyMMdd-HHmmss"
$diagFile   = "$logDir\step18_deploy_v2_diagnostic_$stamp.txt"
$importFile = "$logDir\step18_deploy_v2_import_$stamp.txt"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Log-Line {
    param([string]$Text)
    $Text | Tee-Object -FilePath $diagFile -Append | Write-Host
}

function Get-EnvValue {
    param([string]$File,[string]$Name)

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

function Get-ListenerCount {
    param([int]$Port)

    return @(
        Get-NetTCPConnection `
            -LocalPort $Port `
            -State Listen `
            -ErrorAction SilentlyContinue
    ).Count
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
    }
}

function Get-MT5 {
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

    if (@(Get-WorkerProcesses).Count -ne 0) {
        throw "Trading worker must remain OFF."
    }
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
    }
    while ((Get-Date) -lt $deadline)

    return $false
}

function Wait-TaskNotRunning {
    param(
        [string]$Name,
        [int]$Seconds = 30
    )

    $deadline = (Get-Date).AddSeconds($Seconds)

    do {
        $task = Get-ScheduledTask `
            -TaskName $Name `
            -ErrorAction Stop

        if ($task.State -ne "Running") {
            return $true
        }

        Start-Sleep -Seconds 1
    }
    while ((Get-Date) -lt $deadline)

    return $false
}

function Wait-BridgeHealthy {
    param([int]$Seconds = 240)

    $deadline = (Get-Date).AddSeconds($Seconds)

    do {
        try {
            $health = Invoke-RestMethod `
                -Uri "http://127.0.0.1:8090/health" `
                -TimeoutSec 10

            if (
                $health.status -eq "ok" -and
                $health.mt5_connected -eq $true -and
                $health.live_trading -eq $false -and
                $health.management_enabled -eq $false
            ) {
                return $health
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2
    }
    while ((Get-Date) -lt $deadline)

    return $null
}

function Stop-AbutronBridgeProcesses {
    $targets = @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match "(?i)^python.*\.exe$" -and
            $_.CommandLine -match "mt5_bridge\.app:app" -and
            $_.CommandLine -match "(?i)--port\s+8090"
        }
    )

    foreach ($target in $targets) {
        Log-Line "STOPPING_BRIDGE_PROCESS_PID=$($target.ProcessId)"

        Stop-Process `
            -Id ([int]$target.ProcessId) `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2
}

function Show-BridgeDiagnostics {
    Log-Line ""
    Log-Line "--- BRIDGE DIAGNOSTIC ---"

    try {
        $task = Get-ScheduledTask `
            -TaskName $taskName `
            -ErrorAction Stop

        $info = $task | Get-ScheduledTaskInfo

        Log-Line "TASK_STATE=$($task.State)"
        Log-Line "TASK_LAST_RESULT=$($info.LastTaskResult)"
        Log-Line "TASK_LAST_RUN=$($info.LastRunTime)"
        Log-Line "TASK_IDENTITY=$($task.Principal.UserId)"

        $action = $task.Actions | Select-Object -First 1

        if ($action) {
            Log-Line "TASK_EXECUTE=$($action.Execute)"
            Log-Line "TASK_ARGUMENTS=$($action.Arguments)"
            Log-Line "TASK_WORKING_DIRECTORY=$($action.WorkingDirectory)"
        }
    }
    catch {
        Log-Line "TASK_DIAGNOSTIC_ERROR=$($_.Exception.Message)"
    }

    $listener = Get-ListenerPid 8090

    if ($listener) {
        Log-Line "PORT_8090_LISTENER_PID=$listener"

        try {
            $owner = Get-OwnerInfo $listener
            Log-Line "PORT_8090_OWNER=$($owner.Domain)\$($owner.User)"
            Log-Line "PORT_8090_SESSION=$($owner.Process.SessionId)"
            Log-Line "PORT_8090_COMMAND=$($owner.Process.CommandLine)"
        }
        catch {
            Log-Line "LISTENER_OWNER_ERROR=$($_.Exception.Message)"
        }
    }
    else {
        Log-Line "PORT_8090_LISTENER=NONE"
    }

    $related = @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -match "mt5_bridge\.app:app"
        }
    )

    Log-Line "RELATED_BRIDGE_PROCESS_COUNT=$($related.Count)"

    foreach ($p in $related) {
        Log-Line "RELATED_PID=$($p.ProcessId)"
        Log-Line "RELATED_PARENT_PID=$($p.ParentProcessId)"
        Log-Line "RELATED_SESSION=$($p.SessionId)"
        Log-Line "RELATED_COMMAND=$($p.CommandLine)"
    }
}

function Validate-BridgeTask {
    $task = Get-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction Stop

    $action = $task.Actions |
        Select-Object -First 1

    if ($task.Principal.UserId -notmatch "Administrator") {
        throw "Bridge scheduled task identity is not Administrator."
    }

    if ($action.Execute -ine $pythonExe) {
        throw "Bridge task does not execute production venv Python."
    }

    if ($action.Arguments -notmatch "mt5_bridge\.app:app") {
        throw "Bridge task module is incorrect."
    }

    if ($action.Arguments -notmatch "(?i)--port\s+8090") {
        throw "Bridge task port is incorrect."
    }

    if ($action.WorkingDirectory -ine $root) {
        throw "Bridge task working directory is incorrect."
    }

    if ($action.Arguments -match "abutron\.worker") {
        throw "Worker reference found in Bridge scheduled task."
    }

    Log-Line "BRIDGE_TASK_DEFINITION=PASS"
    Log-Line "BRIDGE_TASK_IDENTITY=Administrator"
    Log-Line "BRIDGE_TASK_DIRECT_PYTHON=PASS"
    Log-Line "BRIDGE_TASK_WORKDIR=PASS"
}

function Clean-RestartBridge {
    param(
        [int]$ExpectedMT5Pid,
        [int]$ExpectedMT5Session
    )

    Log-Line ""
    Log-Line "--- CLEAN BRIDGE RESTART ---"

    Stop-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue

    [void](Wait-TaskNotRunning `
        -Name $taskName `
        -Seconds 30)

    Stop-AbutronBridgeProcesses

    if (-not (Wait-PortFree -Port 8090 -Seconds 60)) {
        throw "Port 8090 did not become free."
    }

    Log-Line "PORT_8090_FREE=PASS"

    Enable-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction Stop |
        Out-Null

    Start-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction Stop

    $health = Wait-BridgeHealthy `
        -Seconds 240

    if (-not $health) {
        Show-BridgeDiagnostics
        throw "Bridge health did not recover within 240 seconds."
    }

    $pid = Get-ListenerPid 8090

    if (-not $pid) {
        throw "Bridge health passed but listener PID is missing."
    }

    if ((Get-ListenerCount 8090) -ne 1) {
        throw "Expected exactly one Bridge listener."
    }

    $owner = Get-OwnerInfo $pid

    if ($owner.User -ine "Administrator") {
        throw "Bridge listener is not Administrator-owned."
    }

    if ([int]$owner.Process.SessionId -ne $ExpectedMT5Session) {
        throw "Bridge listener session does not match MT5 session."
    }

    $task = Get-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction Stop

    if ($task.State -ne "Running") {
        throw "Bridge scheduled task is not Running."
    }

    $mt5Now = @(Get-MT5)

    if ($mt5Now.Count -ne 1) {
        throw "MT5 process count changed."
    }

    if ([int]$mt5Now[0].ProcessId -ne $ExpectedMT5Pid) {
        throw "MT5 PID changed."
    }

    Log-Line "BRIDGE_HEALTH=PASS"
    Log-Line "BRIDGE_PID=$pid"
    Log-Line "BRIDGE_OWNER=$($owner.Domain)\$($owner.User)"
    Log-Line "BRIDGE_SESSION=$($owner.Process.SessionId)"
    Log-Line "BRIDGE_MT5_SESSION_MATCH=PASS"
    Log-Line "BRIDGE_TASK_STATE=Running"
    Log-Line "MT5_PID_CONTINUITY=PASS"

    return @{
        Pid = [int]$pid
        Health = $health
    }
}

Log-Line ""
Log-Line "===================================================="
Log-Line " ABUTRON STEP 18 DEPLOYMENT V2"
Log-Line " ROBUST BRIDGE RECOVERY + MANAGEMENT HARDENING"
Log-Line " NO TRADING / FAIL-CLOSED"
Log-Line "===================================================="

foreach ($required in @(
    $envFile,
    $pythonExe,
    $appFile,
    $patcher,
    $mt5Path
)) {
    if (-not (Test-Path $required)) {
        throw "Missing Step18 prerequisite: $required"
    }
}

Confirm-Safety
Validate-BridgeTask

$mt5 = @(Get-MT5)

if ($mt5.Count -ne 1) {
    throw "Expected exactly one production MT5 terminal."
}

$mt5Pid = [int]$mt5[0].ProcessId
$mt5Session = [int]$mt5[0].SessionId

Log-Line "STEP18_V2_SAFETY_BASELINE=PASS"
Log-Line "MT5_PID=$mt5Pid"
Log-Line "MT5_SESSION=$mt5Session"
Log-Line "WORKER=OFF"
Log-Line "LIVE_TRADING=OFF"
Log-Line "MANAGEMENT=OFF"
Log-Line "ABUTRON_EXECUTION=OFF"

# ============================================================
# 1. RECOVER CURRENT ROLLED-BACK BRIDGE FIRST IF NEEDED
# ============================================================

$currentHealthy = $null

try {
    $currentHealthy = Invoke-RestMethod `
        -Uri "http://127.0.0.1:8090/health" `
        -TimeoutSec 10
}
catch {
}

if (
    -not $currentHealthy -or
    $currentHealthy.status -ne "ok" -or
    $currentHealthy.mt5_connected -ne $true -or
    $currentHealthy.live_trading -ne $false -or
    $currentHealthy.management_enabled -ne $false
) {
    Log-Line "CURRENT_BRIDGE_HEALTHY=False"
    Log-Line "RECOVERING_ROLLED_BACK_BRIDGE=True"

    $baseline = Clean-RestartBridge `
        -ExpectedMT5Pid $mt5Pid `
        -ExpectedMT5Session $mt5Session

    Log-Line "ROLLED_BACK_BRIDGE_RECOVERY=PASS"
}
else {
    Log-Line "CURRENT_BRIDGE_HEALTHY=True"

    $currentPid = Get-ListenerPid 8090

    if (-not $currentPid) {
        throw "Healthy Bridge response without listener PID."
    }

    $currentOwner = Get-OwnerInfo $currentPid

    if ($currentOwner.User -ine "Administrator") {
        throw "Current Bridge is not Administrator-owned."
    }

    if ([int]$currentOwner.Process.SessionId -ne $mt5Session) {
        throw "Current Bridge session does not match MT5."
    }

    Log-Line "CURRENT_BRIDGE_OWNERSHIP=PASS"
    Log-Line "CURRENT_BRIDGE_MT5_SESSION_MATCH=PASS"
}

Confirm-Safety

# ============================================================
# 2. BACKUP + APPLY STEP18 PATCH
# ============================================================

$backup = "$appFile.before-step18-v2-$stamp.bak"

Copy-Item `
    -Path $appFile `
    -Destination $backup `
    -Force

Log-Line "STEP18_V2_BACKUP=$backup"

try {
    & $pythonExe `
        -m py_compile `
        $patcher

    if ($LASTEXITCODE -ne 0) {
        throw "Step18 patcher syntax validation failed."
    }

    Log-Line "STEP18_PATCHER_SYNTAX=PASS"

    & $pythonExe `
        $patcher `
        $appFile

    if ($LASTEXITCODE -ne 0) {
        throw "Step18 management hardening patch failed."
    }

    & $pythonExe `
        -m py_compile `
        $appFile

    if ($LASTEXITCODE -ne 0) {
        throw "Patched mt5_bridge/app.py failed Python syntax."
    }

    Log-Line "STEP18_PATCHED_GATEWAY_SYNTAX=PASS"

    $source = Get-Content $appFile -Raw

    foreach ($marker in @(
        "STEP18_MANAGEMENT_HARDENING_V1",
        "trade_stops_level",
        "trade_freeze_level",
        "MANAGE_ORDER_CHECK_REJECTED",
        "MANAGE_BROKER_CONSTRAINT_NO_SAFE_IMPROVEMENT"
    )) {
        if ($source -notmatch [regex]::Escape($marker)) {
            throw "Patched gateway missing marker: $marker"
        }
    }

    Log-Line "STEP18_PATCHED_GATEWAY_STATIC=PASS"

    # Import the patched module before touching the running task.
    Push-Location $root

    try {
        $importOutput = @(
            & $pythonExe -c "import mt5_bridge.app as a; print('STEP18_PATCHED_GATEWAY_IMPORT=PASS')" 2>&1
        )

        $importExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $importOutput |
        Set-Content `
            -Path $importFile `
            -Encoding UTF8 `
            -Force

    foreach ($line in $importOutput) {
        Log-Line "IMPORT_PROBE=$line"
    }

    if ($importExit -ne 0) {
        throw "Patched gateway import probe failed."
    }

    Log-Line "STEP18_PATCHED_GATEWAY_IMPORT=PASS"

    # ========================================================
    # 3. CLEAN RESTART USING THE PROVEN STEP13C PATTERN
    # ========================================================

    $deployed = Clean-RestartBridge `
        -ExpectedMT5Pid $mt5Pid `
        -ExpectedMT5Session $mt5Session

    Confirm-Safety

    $finalSource = Get-Content $appFile -Raw

    if ($finalSource -notmatch "STEP18_MANAGEMENT_HARDENING_V1") {
        throw "Step18 hardening marker missing after successful restart."
    }

    Log-Line ""
    Log-Line "===================================================="
    Log-Line " STEP 18 MANAGEMENT HARDENING DEPLOYMENT V2 = PASS"
    Log-Line "===================================================="
    Log-Line "STEP18_MANAGEMENT_HARDENING=PASS"
    Log-Line "PATCHED_GATEWAY_IMPORT=PASS"
    Log-Line "CLEAN_PROCESS_SHUTDOWN=PASS"
    Log-Line "PORT_8090_FREE_BEFORE_START=PASS"
    Log-Line "BRIDGE_RESTART_240S_HEALTH=PASS"
    Log-Line "BRIDGE_OWNER=Administrator"
    Log-Line "BRIDGE_MT5_SESSION_MATCH=PASS"
    Log-Line "MT5_PID_CONTINUITY=PASS"
    Log-Line "WORKER=OFF"
    Log-Line "LIVE_TRADING=OFF"
    Log-Line "MANAGEMENT=OFF"
    Log-Line "ABUTRON_EXECUTION=OFF"
    Log-Line "DEMO_ORDER_SENT=False"
    Log-Line "STEP18_CERTIFICATION_STARTED=False"
    Log-Line "===================================================="

    exit 0
}
catch {
    $failure = $_.Exception.Message

    Log-Line ""
    Log-Line "STEP18_V2_DEPLOYMENT_FAILURE=$failure"
    Log-Line "STEP18_V2_ROLLBACK_START=True"

    Show-BridgeDiagnostics

    # Fully clear patched Bridge instance before restoring source.
    Stop-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue

    [void](Wait-TaskNotRunning `
        -Name $taskName `
        -Seconds 30)

    Stop-AbutronBridgeProcesses

    if (-not (Wait-PortFree -Port 8090 -Seconds 60)) {
        Log-Line "ROLLBACK_PORT_CLEAR=FAILED"
        throw
    }

    Copy-Item `
        -Path $backup `
        -Destination $appFile `
        -Force

    Log-Line "STEP18_V2_SOURCE_ROLLBACK=PASS"

    & $pythonExe `
        -m py_compile `
        $appFile

    if ($LASTEXITCODE -ne 0) {
        Log-Line "ROLLBACK_SOURCE_SYNTAX=FAILED"
        throw
    }

    Log-Line "ROLLBACK_SOURCE_SYNTAX=PASS"

    try {
        $restored = Clean-RestartBridge `
            -ExpectedMT5Pid $mt5Pid `
            -ExpectedMT5Session $mt5Session

        Confirm-Safety

        Log-Line "ROLLBACK_BRIDGE_RECOVERY=PASS"
        Log-Line "PLATFORM_RETURNED_TO_SAFE_BASELINE=PASS"
        Log-Line "DEMO_ORDER_SENT=False"
    }
    catch {
        Log-Line "ROLLBACK_BRIDGE_RECOVERY=FAILED"
        Show-BridgeDiagnostics
        throw "Step18 deployment failed and automatic Bridge recovery also failed. Diagnostic: $diagFile"
    }

    throw "Step18 deployment safely rolled back. Diagnostic: $diagFile. Original failure: $failure"
}
