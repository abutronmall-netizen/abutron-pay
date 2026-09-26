$ErrorActionPreference = "Stop"

$root = "C:\Abutron\TradingPlatformV4"
$envFile = "$root\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"
$logDir = "$root\logs"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$coreArguments = "-m uvicorn abutron.api:app --host 127.0.0.1 --port 8088"

$adminOut = "$logDir\core_admin_emergency_stdout.log"
$adminErr = "$logDir\core_admin_emergency_stderr.log"


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

    $item = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if (-not $item) {
        return $null
    }

    return [int]$item.OwningProcess
}


function Get-ProcessOwnerInfo {
    param([int]$PidValue)

    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$PidValue" -ErrorAction Stop
    $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop

    return @{
        Process = $p
        User = $o.User
        Domain = $o.Domain
        Owner = "$($o.Domain)\$($o.User)"
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


function Wait-CoreHealthy {
    param([int]$Seconds = 300)

    $deadline = (Get-Date).AddSeconds($Seconds)

    do {
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:8088/health" -TimeoutSec 10

            if ($health.status -eq "ok" -and $health.kronos_loaded -eq $true -and $health.execution_enabled -eq $false) {
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


function Stop-AbutronCoreProcesses {

    $coreProcesses = @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match '(?i)^python.*\.exe$' -and
            $_.CommandLine -match 'abutron\.api:app' -and
            $_.CommandLine -match '(?i)--port\s+8088'
        }
    )

    foreach ($processItem in $coreProcesses) {
        Stop-Process -Id ([int]$processItem.ProcessId) -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2
}


function Confirm-WorkerOff {

    $workers = @(
        Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -match "abutron\.worker" }
    )

    if ($workers.Count -ne 0) {
        throw "Trading worker unexpectedly running."
    }
}


Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON - CORE PERSISTENCE FINAL REPAIR"
Write-Host " DIRECT SYSTEM PYTHON LAUNCH"
Write-Host " FAIL-CLOSED / NO TRADING"
Write-Host "===================================================="


# ==========================================================
# 1. SAFETY GATE
# ==========================================================

$exec = Get-EnvValue $envFile "ABUTRON_EXECUTION_ENABLED"
$live = Get-EnvValue $envFile "MT5_LIVE_TRADING"
$mgmt = Get-EnvValue $envFile "MT5_MANAGEMENT_ENABLED"
$demo = Get-EnvValue $envFile "MT5_DEMO_ONLY"

if ([string]::IsNullOrWhiteSpace($exec)) {
    throw "ABUTRON_EXECUTION_ENABLED missing."
}

if ([string]::IsNullOrWhiteSpace($live)) {
    throw "MT5_LIVE_TRADING missing."
}

if ([string]::IsNullOrWhiteSpace($mgmt)) {
    throw "MT5_MANAGEMENT_ENABLED missing."
}

if ([string]::IsNullOrWhiteSpace($demo)) {
    throw "MT5_DEMO_ONLY missing."
}

if ($exec.ToLowerInvariant() -ne "false") {
    throw "ABUTRON execution must remain OFF."
}

if ($live.ToLowerInvariant() -ne "false") {
    throw "MT5 live trading must remain OFF."
}

if ($mgmt.ToLowerInvariant() -ne "false") {
    throw "MT5 management must remain OFF."
}

if ($demo.ToLowerInvariant() -ne "true") {
    throw "MT5 demo-only guard must remain ON."
}

Confirm-WorkerOff

Write-Host "SAFETY_GATE=PASS"
Write-Host "WORKER=OFF"


# ==========================================================
# 2. REQUIRED FILES
# ==========================================================

if (-not (Test-Path $pythonExe)) {
    throw "Production venv Python missing: $pythonExe"
}

if (-not (Test-Path $envFile)) {
    throw "Production .env missing."
}

if (-not (Test-Path $mt5Path)) {
    throw "Production MT5 executable missing."
}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

Write-Host "REQUIRED_FILES=PASS"


# ==========================================================
# 3. BASELINE — PROTECT MT5 / BRIDGE / JARVIS
# ==========================================================

$corePidBefore = Get-ListenerPid 8088
$bridgePidBefore = Get-ListenerPid 8090
$jarvisPidBefore = Get-ListenerPid 8787

if (-not $corePidBefore) {
    throw "Current Core listener missing."
}

if (-not $bridgePidBefore) {
    throw "MT5 Bridge listener missing."
}

if (-not $jarvisPidBefore) {
    throw "Jarvis listener missing."
}

$coreBefore = Invoke-RestMethod -Uri "http://127.0.0.1:8088/health" -TimeoutSec 60
$bridgeBefore = Invoke-RestMethod -Uri "http://127.0.0.1:8090/health" -TimeoutSec 60

if ($coreBefore.status -ne "ok") {
    throw "Current Core unhealthy."
}

if ($coreBefore.kronos_loaded -ne $true) {
    throw "Current Kronos not loaded."
}

if ($coreBefore.execution_enabled -ne $false) {
    throw "Core execution unexpectedly enabled."
}

if ($bridgeBefore.status -ne "ok") {
    throw "MT5 Bridge unhealthy."
}

if ($bridgeBefore.mt5_connected -ne $true) {
    throw "MT5 disconnected."
}

if ($bridgeBefore.live_trading -ne $false) {
    throw "MT5 live trading unexpectedly enabled."
}

if ($bridgeBefore.management_enabled -ne $false) {
    throw "MT5 management unexpectedly enabled."
}

$mt5Before = @(
    Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -ieq "terminal64.exe" -and
        $_.ExecutablePath -ieq $mt5Path
    }
)

if ($mt5Before.Count -ne 1) {
    throw "Expected exactly one production MT5 terminal."
}

$mt5PidBefore = [int]$mt5Before[0].ProcessId

$currentOwner = Get-ProcessOwnerInfo $corePidBefore

Write-Host ""
Write-Host "--- CURRENT PRODUCTION ---"
Write-Host "CORE_PID_BEFORE=$corePidBefore"
Write-Host "CORE_OWNER_BEFORE=$($currentOwner.Owner)"
Write-Host "BRIDGE_PID=$bridgePidBefore"
Write-Host "MT5_PID=$mt5PidBefore"
Write-Host "JARVIS_PID=$jarvisPidBefore"
Write-Host "BASELINE_HEALTH=PASS"


# ==========================================================
# 4. REPLACE CORE TASK WITH DIRECT PYTHON ACTION
# ==========================================================

Stop-ScheduledTask -TaskName "Abutron-Core" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

Unregister-ScheduledTask -TaskName "Abutron-Core" -Confirm:$false -ErrorAction SilentlyContinue

$taskAction = New-ScheduledTaskAction `
    -Execute $pythonExe `
    -Argument $coreArguments `
    -WorkingDirectory $root

$taskTrigger = New-ScheduledTaskTrigger -AtStartup

$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$taskSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

$newTask = New-ScheduledTask `
    -Action $taskAction `
    -Trigger $taskTrigger `
    -Principal $taskPrincipal `
    -Settings $taskSettings

Register-ScheduledTask `
    -TaskName "Abutron-Core" `
    -InputObject $newTask `
    -Force |
    Out-Null

Enable-ScheduledTask -TaskName "Abutron-Core" | Out-Null

$taskVerify = Get-ScheduledTask -TaskName "Abutron-Core" -ErrorAction Stop

if ($taskVerify.Principal.UserId -ne "SYSTEM") {
    throw "New Core task is not SYSTEM-owned."
}

$actionVerify = $taskVerify.Actions | Select-Object -First 1

if ($actionVerify.Execute -ine $pythonExe) {
    throw "Core task does not directly execute the production venv Python."
}

if ($actionVerify.Arguments -notmatch "abutron\.api:app") {
    throw "Core task does not launch Abutron API."
}

if ($actionVerify.Arguments -notmatch "8088") {
    throw "Core task does not target port 8088."
}

if ($actionVerify.Arguments -match "abutron\.worker") {
    throw "Worker reference detected in Core task."
}

if ($actionVerify.Arguments -match "start_platform") {
    throw "Unsafe platform launcher detected in Core task."
}

Write-Host ""
Write-Host "DIRECT_SYSTEM_TASK_BUILD=PASS"
Write-Host "CORE_TASK_EXECUTABLE=$($actionVerify.Execute)"
Write-Host "CORE_TASK_IDENTITY=SYSTEM"
Write-Host "CORE_TASK_WRAPPER_USED=False"


# ==========================================================
# 5. CONTROLLED CUTOVER
# ==========================================================

Write-Host ""
Write-Host "--- STOPPING OLD ADMIN CORE ---"

Stop-AbutronCoreProcesses

$portFreed = Wait-PortFree -Port 8088 -Seconds 60

if (-not $portFreed) {
    Disable-ScheduledTask -TaskName "Abutron-Core" | Out-Null
    throw "Port 8088 did not become free."
}

Write-Host "OLD_CORE_STOPPED=PASS"
Write-Host "PORT_8088_FREE=PASS"


# ==========================================================
# 6. START CORE THROUGH SYSTEM TASK
# ==========================================================

Write-Host ""
Write-Host "--- STARTING CORE AS SYSTEM ---"

Start-ScheduledTask -TaskName "Abutron-Core"

$coreAfter = Wait-CoreHealthy -Seconds 300

$migrationPassed = $false
$migrationReason = ""


if (-not $coreAfter) {
    $migrationReason = "Core health did not recover."
}
else {

    $corePidAfter = Get-ListenerPid 8088

    if (-not $corePidAfter) {
        $migrationReason = "Core health responded but listener PID missing."
    }
    else {

        try {
            $systemOwner = Get-ProcessOwnerInfo $corePidAfter

            if ($systemOwner.User -ine "SYSTEM") {
                $migrationReason = "Core listener owner is $($systemOwner.Owner), not SYSTEM."
            }
            else {

                $runningTask = Get-ScheduledTask -TaskName "Abutron-Core" -ErrorAction Stop

                if ($runningTask.State -ne "Running") {
                    $migrationReason = "Core task state is $($runningTask.State), expected Running."
                }
                else {
                    $migrationPassed = $true
                }
            }
        }
        catch {
            $migrationReason = $_.Exception.Message
        }
    }
}


# ==========================================================
# 7. SUCCESS PATH
# ==========================================================

if ($migrationPassed) {

    $corePidAfter = Get-ListenerPid 8088
    $systemOwner = Get-ProcessOwnerInfo $corePidAfter

    if ($coreAfter.status -ne "ok") {
        throw "Core final health failed."
    }

    if ($coreAfter.kronos_loaded -ne $true) {
        throw "Kronos did not warm-load."
    }

    if ($coreAfter.execution_enabled -ne $false) {
        throw "Execution became enabled."
    }

    if ((Get-ListenerPid 8090) -ne $bridgePidBefore) {
        throw "Bridge restarted unexpectedly."
    }

    if ((Get-ListenerPid 8787) -ne $jarvisPidBefore) {
        throw "Jarvis restarted unexpectedly."
    }

    $bridgeAfter = Invoke-RestMethod -Uri "http://127.0.0.1:8090/health" -TimeoutSec 60

    if ($bridgeAfter.status -ne "ok") {
        throw "Bridge unhealthy after Core migration."
    }

    if ($bridgeAfter.mt5_connected -ne $true) {
        throw "MT5 disconnected after Core migration."
    }

    if ($bridgeAfter.live_trading -ne $false) {
        throw "Live trading changed."
    }

    if ($bridgeAfter.management_enabled -ne $false) {
        throw "Management changed."
    }

    $mt5After = @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -ieq "terminal64.exe" -and
            $_.ExecutablePath -ieq $mt5Path
        }
    )

    if ($mt5After.Count -ne 1) {
        throw "MT5 process count changed."
    }

    $mt5PidAfter = [int]$mt5After[0].ProcessId

    if ($mt5PidAfter -ne $mt5PidBefore) {
        throw "MT5 restarted unexpectedly."
    }

    Confirm-WorkerOff

    $taskFinal = Get-ScheduledTask -TaskName "Abutron-Core"
    $taskInfoFinal = Get-ScheduledTaskInfo -TaskName "Abutron-Core"

    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 13C.2B = PASS"
    Write-Host "===================================================="
    Write-Host "CORE_PERSISTENCE_REPAIRED=PASS"
    Write-Host "DIRECT_PYTHON_TASK=PASS"
    Write-Host "POWERSHELL_WRAPPER_REMOVED_FROM_TASK=PASS"
    Write-Host "CORE_SYSTEM_MIGRATION=PASS"
    Write-Host "CORE_OWNER=$($systemOwner.Owner)"
    Write-Host "CORE_PID=$corePidAfter"
    Write-Host "CORE_TASK_STATE=$($taskFinal.State)"
    Write-Host "CORE_TASK_LAST_RESULT=$($taskInfoFinal.LastTaskResult)"
    Write-Host "KRONOS_RELOAD=PASS"
    Write-Host "BRIDGE_PROCESS_UNCHANGED=PASS"
    Write-Host "MT5_PROCESS_UNCHANGED=PASS"
    Write-Host "JARVIS_PROCESS_UNCHANGED=PASS"
    Write-Host "MT5_CONNECTED=True"
    Write-Host "WORKER=OFF"
    Write-Host "LIVE_TRADING=OFF"
    Write-Host "MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"
    Write-Host "NO_TRADES_SENT"
    Write-Host "===================================================="

    exit 0
}


# ==========================================================
# 8. FAILURE PATH — FAIL CLOSED + RESTORE ADMIN CORE
# ==========================================================

Write-Host ""
Write-Host "===================================================="
Write-Host " SYSTEM MIGRATION FAILED"
Write-Host " AUTOMATIC SAFE RECOVERY STARTING"
Write-Host "===================================================="
Write-Host "MIGRATION_FAILURE=$migrationReason"

$failedTask = Get-ScheduledTask -TaskName "Abutron-Core" -ErrorAction SilentlyContinue

if ($failedTask) {
    $failedInfo = Get-ScheduledTaskInfo -TaskName "Abutron-Core" -ErrorAction SilentlyContinue

    Write-Host "FAILED_TASK_STATE=$($failedTask.State)"

    if ($failedInfo) {
        Write-Host "FAILED_TASK_LAST_RESULT=$($failedInfo.LastTaskResult)"
        Write-Host "FAILED_TASK_LAST_RUN=$($failedInfo.LastRunTime)"
    }
}

Stop-ScheduledTask -TaskName "Abutron-Core" -ErrorAction SilentlyContinue
Disable-ScheduledTask -TaskName "Abutron-Core" -ErrorAction SilentlyContinue | Out-Null

Stop-AbutronCoreProcesses
Start-Sleep -Seconds 2

$portFreedAgain = Wait-PortFree -Port 8088 -Seconds 60

if (-not $portFreedAgain) {
    throw "Could not clear failed SYSTEM Core process."
}

Remove-Item $adminOut -Force -ErrorAction SilentlyContinue
Remove-Item $adminErr -Force -ErrorAction SilentlyContinue

$adminArgumentList = @(
    "-m",
    "uvicorn",
    "abutron.api:app",
    "--host",
    "127.0.0.1",
    "--port",
    "8088"
)

Start-Process `
    -FilePath $pythonExe `
    -ArgumentList $adminArgumentList `
    -WorkingDirectory $root `
    -RedirectStandardOutput $adminOut `
    -RedirectStandardError $adminErr

$recovered = Wait-CoreHealthy -Seconds 300

if (-not $recovered) {

    Write-Host "ADMIN_RECOVERY=FAILED"

    if (Test-Path $adminErr) {
        Write-Host "--- ADMIN STDERR ---"
        Get-Content $adminErr -Tail 100
    }

    throw "Core could not be recovered."
}

$recoveredPid = Get-ListenerPid 8088
$recoveredOwner = Get-ProcessOwnerInfo $recoveredPid

if ($recovered.execution_enabled -ne $false) {
    throw "Recovered Core execution is not OFF."
}

$bridgeRecovery = Invoke-RestMethod -Uri "http://127.0.0.1:8090/health" -TimeoutSec 60

if ($bridgeRecovery.live_trading -ne $false) {
    throw "Live trading changed during recovery."
}

if ($bridgeRecovery.management_enabled -ne $false) {
    throw "Management changed during recovery."
}

Confirm-WorkerOff

Write-Host ""
Write-Host "ADMIN_RECOVERY=PASS"
Write-Host "RECOVERED_CORE_PID=$recoveredPid"
Write-Host "RECOVERED_CORE_OWNER=$($recoveredOwner.Owner)"
Write-Host "KRONOS_LOADED=True"
Write-Host "CORE_EXECUTION=False"
Write-Host "FAILED_SYSTEM_TASK_DISABLED=True"
Write-Host "WORKER=OFF"
Write-Host "LIVE_TRADING=OFF"
Write-Host "MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "NO_TRADES_SENT"

throw "Core was safely recovered, but SYSTEM persistence migration still requires investigation."
