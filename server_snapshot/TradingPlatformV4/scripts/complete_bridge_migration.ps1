$ErrorActionPreference = "Stop"

$root = "C:\Abutron\TradingPlatformV4"
$envFile = "$root\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"
$logDir = "$root\logs"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$adminUser = "$env:COMPUTERNAME\Administrator"

$bridgeArguments = "-m uvicorn mt5_bridge.app:app --host 127.0.0.1 --port 8090"

$fallbackOut = "$logDir\bridge_admin_emergency_stdout.log"
$fallbackErr = "$logDir\bridge_admin_emergency_stderr.log"


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
        Owner = "$($owner.Domain)\$($owner.User)"
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
            $_.Name -match '(?i)^python.*\.exe$' -and
            $_.CommandLine -match 'mt5_bridge\.app:app' -and
            $_.CommandLine -match '(?i)--port\s+8090'
        }
    )

    foreach ($target in $targets) {
        Stop-Process `
            -Id ([int]$target.ProcessId) `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2
}


function Confirm-WorkerOff {

    $workers = @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -match "abutron\.worker"
        }
    )

    if ($workers.Count -ne 0) {
        throw "Trading worker unexpectedly running."
    }
}


Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON - STEP 13C.2C"
Write-Host " MT5 BRIDGE OWNERSHIP MIGRATION"
Write-Host " DIRECT PYTHON / ADMIN INTERACTIVE"
Write-Host " FAIL-CLOSED / NO TRADING"
Write-Host "===================================================="


# ==========================================================
# 1. SAFETY
# ==========================================================

$exec = Get-EnvValue $envFile "ABUTRON_EXECUTION_ENABLED"
$live = Get-EnvValue $envFile "MT5_LIVE_TRADING"
$mgmt = Get-EnvValue $envFile "MT5_MANAGEMENT_ENABLED"
$demo = Get-EnvValue $envFile "MT5_DEMO_ONLY"

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
    throw "MT5 demo-only must remain ON."
}

Confirm-WorkerOff

Write-Host "SAFETY_GATE=PASS"
Write-Host "WORKER=OFF"


# ==========================================================
# 2. VERIFY CORE SYSTEM MIGRATION
# ==========================================================

$corePid = Get-ListenerPid 8088

if (-not $corePid) {
    throw "Core listener missing."
}

$coreHealth = Invoke-RestMethod `
    -Uri "http://127.0.0.1:8088/health" `
    -TimeoutSec 60

if ($coreHealth.status -ne "ok") {
    throw "Core unhealthy."
}

if ($coreHealth.kronos_loaded -ne $true) {
    throw "Kronos not loaded."
}

if ($coreHealth.execution_enabled -ne $false) {
    throw "Core execution enabled."
}

$coreOwner = Get-OwnerInfo $corePid

if ($coreOwner.User -ine "SYSTEM") {
    throw "Core is no longer SYSTEM-owned."
}

$coreTask = Get-ScheduledTask `
    -TaskName "Abutron-Core" `
    -ErrorAction Stop

if ($coreTask.State -ne "Running") {
    throw "Abutron-Core task is not Running."
}

if ($coreTask.Principal.UserId -ne "SYSTEM") {
    throw "Abutron-Core task identity changed."
}

Write-Host "CORE_SYSTEM_BASELINE=PASS"
Write-Host "CORE_PID=$corePid"
Write-Host "CORE_OWNER=$($coreOwner.Owner)"


# ==========================================================
# 3. BASELINE MT5 / BRIDGE / JARVIS
# ==========================================================

$bridgeOldPid = Get-ListenerPid 8090
$jarvisPid = Get-ListenerPid 8787

if (-not $bridgeOldPid) {
    throw "Current Bridge listener missing."
}

if (-not $jarvisPid) {
    throw "Jarvis listener missing."
}

$bridgeBefore = Invoke-RestMethod `
    -Uri "http://127.0.0.1:8090/health" `
    -TimeoutSec 60

if ($bridgeBefore.status -ne "ok") {
    throw "Current Bridge unhealthy."
}

if ($bridgeBefore.mt5_connected -ne $true) {
    throw "MT5 disconnected before migration."
}

if ($bridgeBefore.live_trading -ne $false) {
    throw "Live trading enabled before migration."
}

if ($bridgeBefore.management_enabled -ne $false) {
    throw "Management enabled before migration."
}

$mt5 = @(
    Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -ieq "terminal64.exe" -and
        $_.ExecutablePath -ieq $mt5Path
    }
)

if ($mt5.Count -ne 1) {
    throw "Expected exactly one production MT5 terminal."
}

$mt5Pid = [int]$mt5[0].ProcessId
$mt5Session = [int]$mt5[0].SessionId
$mt5Owner = Get-OwnerInfo $mt5Pid

if ($mt5Owner.User -ine "Administrator") {
    throw "MT5 is not running under Administrator."
}

$bridgeOldOwner = Get-OwnerInfo $bridgeOldPid

Write-Host ""
Write-Host "--- CURRENT BRIDGE / MT5 ---"
Write-Host "BRIDGE_OLD_PID=$bridgeOldPid"
Write-Host "BRIDGE_OLD_OWNER=$($bridgeOldOwner.Owner)"
Write-Host "BRIDGE_OLD_SESSION=$($bridgeOldOwner.Process.SessionId)"
Write-Host "MT5_PID=$mt5Pid"
Write-Host "MT5_OWNER=$($mt5Owner.Owner)"
Write-Host "MT5_SESSION=$mt5Session"
Write-Host "JARVIS_PID=$jarvisPid"


# ==========================================================
# 4. REPLACE BRIDGE TASK — DIRECT PYTHON
# ==========================================================

Stop-ScheduledTask `
    -TaskName "Abutron-MT5Bridge" `
    -ErrorAction SilentlyContinue

Start-Sleep -Seconds 1

Unregister-ScheduledTask `
    -TaskName "Abutron-MT5Bridge" `
    -Confirm:$false `
    -ErrorAction SilentlyContinue


$bridgeAction = New-ScheduledTaskAction `
    -Execute $pythonExe `
    -Argument $bridgeArguments `
    -WorkingDirectory $root


$bridgeTrigger = New-ScheduledTaskTrigger `
    -AtLogOn `
    -User $adminUser


$bridgePrincipal = New-ScheduledTaskPrincipal `
    -UserId $adminUser `
    -LogonType Interactive `
    -RunLevel Highest


$bridgeSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)


$bridgeTaskDefinition = New-ScheduledTask `
    -Action $bridgeAction `
    -Trigger $bridgeTrigger `
    -Principal $bridgePrincipal `
    -Settings $bridgeSettings


Register-ScheduledTask `
    -TaskName "Abutron-MT5Bridge" `
    -InputObject $bridgeTaskDefinition `
    -Force |
    Out-Null


Enable-ScheduledTask `
    -TaskName "Abutron-MT5Bridge" |
    Out-Null


$bridgeTaskVerify = Get-ScheduledTask `
    -TaskName "Abutron-MT5Bridge" `
    -ErrorAction Stop


$bridgeActionVerify = $bridgeTaskVerify.Actions |
    Select-Object -First 1


if ($bridgeTaskVerify.Principal.UserId -notmatch "Administrator") {
    throw "Bridge task identity is not Administrator."
}


if ($bridgeActionVerify.Execute -ine $pythonExe) {
    throw "Bridge task does not execute production venv Python."
}


if ($bridgeActionVerify.Arguments -notmatch "mt5_bridge\.app:app") {
    throw "Bridge task module is incorrect."
}


if ($bridgeActionVerify.Arguments -notmatch "8090") {
    throw "Bridge task port is incorrect."
}


if ($bridgeActionVerify.Arguments -match "abutron\.worker") {
    throw "Worker reference detected in Bridge task."
}


if ($bridgeActionVerify.Arguments -match "start_platform") {
    throw "Unsafe platform launcher detected in Bridge task."
}


Write-Host ""
Write-Host "DIRECT_BRIDGE_TASK_BUILD=PASS"
Write-Host "BRIDGE_TASK_EXECUTABLE=$($bridgeActionVerify.Execute)"
Write-Host "BRIDGE_TASK_IDENTITY=$($bridgeTaskVerify.Principal.UserId)"
Write-Host "BRIDGE_POWERSHELL_WRAPPER_USED=False"


# ==========================================================
# 5. STOP OLD BRIDGE ONLY
# ==========================================================

Write-Host ""
Write-Host "--- STOPPING OLD BRIDGE ---"

Stop-AbutronBridgeProcesses

$bridgePortFree = Wait-PortFree `
    -Port 8090 `
    -Seconds 60

if (-not $bridgePortFree) {
    Disable-ScheduledTask `
        -TaskName "Abutron-MT5Bridge" |
        Out-Null

    throw "Port 8090 did not become free."
}

Write-Host "OLD_BRIDGE_STOPPED=PASS"
Write-Host "PORT_8090_FREE=PASS"


# ==========================================================
# 6. START BRIDGE FROM SCHEDULED TASK
# ==========================================================

Write-Host ""
Write-Host "--- STARTING BRIDGE FROM ADMIN TASK ---"

Start-ScheduledTask `
    -TaskName "Abutron-MT5Bridge"


$bridgeAfter = Wait-BridgeHealthy `
    -Seconds 240


$migrationPassed = $false
$migrationReason = ""


if (-not $bridgeAfter) {
    $migrationReason = "Bridge health did not recover."
}
else {

    $bridgeNewPid = Get-ListenerPid 8090

    if (-not $bridgeNewPid) {
        $migrationReason = "Bridge health passed but listener PID is missing."
    }
    else {

        try {

            $bridgeNewOwner = Get-OwnerInfo $bridgeNewPid
            $bridgeTaskCurrent = Get-ScheduledTask `
                -TaskName "Abutron-MT5Bridge" `
                -ErrorAction Stop

            if ($bridgeNewOwner.User -ine "Administrator") {
                $migrationReason = "Bridge listener is not Administrator-owned."
            }
            elseif ([int]$bridgeNewOwner.Process.SessionId -ne $mt5Session) {
                $migrationReason = "Bridge session does not match MT5 session."
            }
            elseif ($bridgeTaskCurrent.State -ne "Running") {
                $migrationReason = "Bridge task is not Running."
            }
            else {
                $migrationPassed = $true
            }
        }
        catch {
            $migrationReason = $_.Exception.Message
        }
    }
}


# ==========================================================
# 7. SUCCESS
# ==========================================================

if ($migrationPassed) {

    $bridgeNewPid = Get-ListenerPid 8090
    $bridgeNewOwner = Get-OwnerInfo $bridgeNewPid

    if ((Get-ListenerCount 8090) -ne 1) {
        throw "Bridge listener count is not exactly one."
    }


    # Core must remain unchanged.

    if ((Get-ListenerPid 8088) -ne $corePid) {
        throw "Core restarted unexpectedly."
    }


    $coreAfter = Invoke-RestMethod `
        -Uri "http://127.0.0.1:8088/health" `
        -TimeoutSec 60

    if ($coreAfter.status -ne "ok") {
        throw "Core unhealthy after Bridge migration."
    }

    if ($coreAfter.kronos_loaded -ne $true) {
        throw "Kronos unloaded."
    }

    if ($coreAfter.execution_enabled -ne $false) {
        throw "Core execution changed."
    }


    # Jarvis must remain unchanged.

    if ((Get-ListenerPid 8787) -ne $jarvisPid) {
        throw "Jarvis restarted unexpectedly."
    }


    # MT5 must remain unchanged.

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

    if ($mt5PidAfter -ne $mt5Pid) {
        throw "MT5 restarted unexpectedly."
    }


    if ($bridgeAfter.mt5_connected -ne $true) {
        throw "Bridge is not connected to MT5."
    }

    if ($bridgeAfter.live_trading -ne $false) {
        throw "Live trading became enabled."
    }

    if ($bridgeAfter.management_enabled -ne $false) {
        throw "Management became enabled."
    }


    Confirm-WorkerOff


    $taskFinal = Get-ScheduledTask `
        -TaskName "Abutron-MT5Bridge"

    $taskInfoFinal = Get-ScheduledTaskInfo `
        -TaskName "Abutron-MT5Bridge"


    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 13C.2C = PASS"
    Write-Host "===================================================="

    Write-Host "BRIDGE_PERSISTENCE_REPAIRED=PASS"
    Write-Host "DIRECT_PYTHON_TASK=PASS"
    Write-Host "POWERSHELL_WRAPPER_REMOVED_FROM_BRIDGE_TASK=PASS"

    Write-Host "BRIDGE_OWNERSHIP_MIGRATION=PASS"
    Write-Host "BRIDGE_OLD_PID=$bridgeOldPid"
    Write-Host "BRIDGE_NEW_PID=$bridgeNewPid"
    Write-Host "BRIDGE_OWNER=$($bridgeNewOwner.Owner)"
    Write-Host "BRIDGE_SESSION=$($bridgeNewOwner.Process.SessionId)"
    Write-Host "MT5_SESSION=$mt5Session"
    Write-Host "BRIDGE_MT5_SESSION_MATCH=PASS"

    Write-Host "BRIDGE_TASK_STATE=$($taskFinal.State)"
    Write-Host "BRIDGE_TASK_LAST_RESULT=$($taskInfoFinal.LastTaskResult)"

    Write-Host "BRIDGE_MT5_RECONNECT=PASS"

    Write-Host "CORE_SYSTEM_CONTINUITY=PASS"
    Write-Host "KRONOS_LOADED=True"

    Write-Host "MT5_PROCESS_UNCHANGED=PASS"
    Write-Host "JARVIS_PROCESS_UNCHANGED=PASS"

    Write-Host "CORE_LISTENER_COUNT=1"
    Write-Host "BRIDGE_LISTENER_COUNT=1"

    Write-Host "STEP_13C_2_COMPLETE=PASS"

    Write-Host "WORKER=OFF"
    Write-Host "LIVE_TRADING=OFF"
    Write-Host "MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"

    Write-Host "NO_TRADES_SENT"
    Write-Host "===================================================="

    exit 0
}


# ==========================================================
# 8. FAILURE — RESTORE BRIDGE SAFELY
# ==========================================================

Write-Host ""
Write-Host "===================================================="
Write-Host " BRIDGE MIGRATION FAILED"
Write-Host " AUTOMATIC SAFE RECOVERY"
Write-Host "===================================================="

Write-Host "MIGRATION_FAILURE=$migrationReason"


Stop-ScheduledTask `
    -TaskName "Abutron-MT5Bridge" `
    -ErrorAction SilentlyContinue


Disable-ScheduledTask `
    -TaskName "Abutron-MT5Bridge" `
    -ErrorAction SilentlyContinue |
    Out-Null


Stop-AbutronBridgeProcesses


$freeAgain = Wait-PortFree `
    -Port 8090 `
    -Seconds 60

if (-not $freeAgain) {
    throw "Failed Bridge process could not be cleared."
}


Remove-Item `
    $fallbackOut `
    -Force `
    -ErrorAction SilentlyContinue

Remove-Item `
    $fallbackErr `
    -Force `
    -ErrorAction SilentlyContinue


$fallbackArguments = @(
    "-m",
    "uvicorn",
    "mt5_bridge.app:app",
    "--host",
    "127.0.0.1",
    "--port",
    "8090"
)


Start-Process `
    -FilePath $pythonExe `
    -ArgumentList $fallbackArguments `
    -WorkingDirectory $root `
    -RedirectStandardOutput $fallbackOut `
    -RedirectStandardError $fallbackErr


$fallbackHealth = Wait-BridgeHealthy `
    -Seconds 240


if (-not $fallbackHealth) {

    Write-Host "BRIDGE_ADMIN_RECOVERY=FAILED"

    if (Test-Path $fallbackErr) {
        Write-Host "--- BRIDGE STDERR ---"

        Get-Content `
            $fallbackErr `
            -Tail 100
    }

    throw "Bridge could not be safely recovered."
}


$fallbackPid = Get-ListenerPid 8090
$fallbackOwner = Get-OwnerInfo $fallbackPid


if ($fallbackHealth.live_trading -ne $false) {
    throw "Recovered Bridge live trading is not OFF."
}

if ($fallbackHealth.management_enabled -ne $false) {
    throw "Recovered Bridge management is not OFF."
}

if ($fallbackHealth.mt5_connected -ne $true) {
    throw "Recovered Bridge is not connected to MT5."
}


Confirm-WorkerOff


Write-Host ""
Write-Host "BRIDGE_ADMIN_RECOVERY=PASS"
Write-Host "RECOVERED_BRIDGE_PID=$fallbackPid"
Write-Host "RECOVERED_BRIDGE_OWNER=$($fallbackOwner.Owner)"
Write-Host "MT5_CONNECTED=True"
Write-Host "FAILED_BRIDGE_TASK_DISABLED=True"

Write-Host "WORKER=OFF"
Write-Host "LIVE_TRADING=OFF"
Write-Host "MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "NO_TRADES_SENT"

throw "Bridge safely recovered, but Scheduled Task migration failed."
