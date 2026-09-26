$ErrorActionPreference = "Stop"

$root      = "C:\Abutron\TradingPlatformV4"
$envFile   = "$root\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"
$appFile   = "$root\mt5_bridge\app.py"
$patcher   = "$root\scripts\step18_manage_hardening_patch.py"
$taskName  = "Abutron-MT5Bridge"
$mt5Path   = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

function Get-EnvValue {
    param([string]$File,[string]$Name)
    $escaped = [regex]::Escape($Name)
    $line = Get-Content $File |
        Where-Object { $_ -match "^\s*$escaped\s*=" } |
        Select-Object -First 1
    if (-not $line) { return $null }
    return (($line -split "=",2)[1]).Trim().Trim('"').Trim("'")
}

function Get-ListenerPid {
    param([int]$Port)
    $item = Get-NetTCPConnection `
        -LocalPort $Port `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $item) { return $null }
    return [int]$item.OwningProcess
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

function Get-Owner {
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

function Confirm-Safety {
    $exec = [string](Get-EnvValue $envFile "ABUTRON_EXECUTION_ENABLED")
    $live = [string](Get-EnvValue $envFile "MT5_LIVE_TRADING")
    $mgmt = [string](Get-EnvValue $envFile "MT5_MANAGEMENT_ENABLED")
    $demo = [string](Get-EnvValue $envFile "MT5_DEMO_ONLY")

    if ($exec.ToLowerInvariant() -ne "false") { throw "ABUTRON_EXECUTION_ENABLED must remain false." }
    if ($live.ToLowerInvariant() -ne "false") { throw "MT5_LIVE_TRADING must remain false." }
    if ($mgmt.ToLowerInvariant() -ne "false") { throw "MT5_MANAGEMENT_ENABLED must remain false." }
    if ($demo.ToLowerInvariant() -ne "true") { throw "MT5_DEMO_ONLY must remain true." }

    $workers = @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -match "(?i)(-m\s+abutron\.worker|abutron\\worker\.py)"
        }
    )

    if ($workers.Count -ne 0) {
        throw "Trading worker must remain OFF."
    }
}

function Wait-Bridge {
    param(
        [int]$OldPid,
        [int]$Seconds = 120
    )

    $deadline = (Get-Date).AddSeconds($Seconds)

    do {
        try {
            $pid = Get-ListenerPid 8090

            if ($pid -and $pid -ne $OldPid) {
                $health = Invoke-RestMethod `
                    -Uri "http://127.0.0.1:8090/health" `
                    -TimeoutSec 10

                if (
                    $health.status -eq "ok" -and
                    $health.mt5_connected -eq $true -and
                    $health.live_trading -eq $false -and
                    $health.management_enabled -eq $false
                ) {
                    return @{
                        Pid = $pid
                        Health = $health
                    }
                }
            }
        }
        catch {
        }

        Start-Sleep -Seconds 2

    } while ((Get-Date) -lt $deadline)

    return $null
}

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 18 - MANAGEMENT HARDENING DEPLOYMENT"
Write-Host " BRIDGE-ONLY CONTROLLED RESTART / NO TRADING"
Write-Host "===================================================="

foreach ($required in @(
    $envFile,
    $pythonExe,
    $appFile,
    $patcher,
    $mt5Path
)) {
    if (-not (Test-Path $required)) {
        throw "Missing Step18 deployment prerequisite: $required"
    }
}

Confirm-Safety

$mt5 = @(Get-MT5)

if ($mt5.Count -ne 1) {
    throw "Expected exactly one production MT5 terminal."
}

$mt5Pid = [int]$mt5[0].ProcessId
$mt5Session = [int]$mt5[0].SessionId

$bridgePidBefore = Get-ListenerPid 8090

if (-not $bridgePidBefore) {
    throw "Production MT5 Bridge listener is missing."
}

$bridgeOwnerBefore = Get-Owner $bridgePidBefore

if ($bridgeOwnerBefore.User -ine "Administrator") {
    throw "Bridge is not Administrator-owned."
}

if ([int]$bridgeOwnerBefore.Process.SessionId -ne $mt5Session) {
    throw "Bridge and MT5 are not in the same Windows session."
}

Write-Host "STEP18_DEPLOY_SAFETY_BASELINE=PASS"
Write-Host "BRIDGE_PID_BEFORE=$bridgePidBefore"
Write-Host "MT5_PID=$mt5Pid"
Write-Host "BRIDGE_MT5_SESSION_MATCH_BEFORE=PASS"
Write-Host "WORKER=OFF"
Write-Host "LIVE_TRADING=OFF"
Write-Host "MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$wrapperBackup = "$appFile.before-step18-deploy-$stamp.bak"

Copy-Item `
    -Path $appFile `
    -Destination $wrapperBackup `
    -Force

Write-Host "STEP18_DEPLOY_BACKUP=PASS"

try {
    & $pythonExe `
        -m py_compile `
        $patcher

    if ($LASTEXITCODE -ne 0) {
        throw "Step18 hardening patcher syntax failed."
    }

    Write-Host "STEP18_PATCHER_SYNTAX=PASS"

    & $pythonExe `
        $patcher `
        $appFile

    if ($LASTEXITCODE -ne 0) {
        throw "Step18 hardening patch failed."
    }

    & $pythonExe `
        -m py_compile `
        $appFile

    if ($LASTEXITCODE -ne 0) {
        throw "Patched mt5_bridge/app.py failed Python syntax."
    }

    Write-Host "STEP18_PATCHED_GATEWAY_SYNTAX=PASS"

    $source = Get-Content $appFile -Raw

    foreach ($marker in @(
        "STEP18_MANAGEMENT_HARDENING_V1",
        "trade_stops_level",
        "trade_freeze_level",
        "MANAGE_ORDER_CHECK_REJECTED",
        "MANAGE_BROKER_CONSTRAINT_NO_SAFE_IMPROVEMENT"
    )) {
        if ($source -notmatch [regex]::Escape($marker)) {
            throw "Patched gateway missing Step18 marker: $marker"
        }
    }

    Write-Host "STEP18_PATCHED_GATEWAY_STATIC=PASS"

    Stop-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2

    Start-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction Stop

    $bridge = Wait-Bridge `
        -OldPid $bridgePidBefore `
        -Seconds 120

    if (-not $bridge) {
        throw "Patched Bridge failed controlled restart/health."
    }

    $bridgePidAfter = [int]$bridge.Pid
    $bridgeOwnerAfter = Get-Owner $bridgePidAfter

    if ($bridgeOwnerAfter.User -ine "Administrator") {
        throw "Restarted Bridge is not Administrator-owned."
    }

    if ([int]$bridgeOwnerAfter.Process.SessionId -ne $mt5Session) {
        throw "Restarted Bridge lost MT5 Windows-session alignment."
    }

    if ((@(Get-MT5)).Count -ne 1) {
        throw "MT5 process count changed during Bridge deployment."
    }

    if ([int](@(Get-MT5))[0].ProcessId -ne $mt5Pid) {
        throw "MT5 PID changed during Bridge deployment."
    }

    Confirm-Safety

    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 18 MANAGEMENT HARDENING DEPLOYMENT = PASS"
    Write-Host "===================================================="
    Write-Host "STEP18_MANAGEMENT_HARDENING=PASS"
    Write-Host "BRIDGE_CONTROLLED_RESTART=PASS"
    Write-Host "BRIDGE_PID_AFTER=$bridgePidAfter"
    Write-Host "BRIDGE_OWNER=Administrator"
    Write-Host "BRIDGE_MT5_SESSION_MATCH_AFTER=PASS"
    Write-Host "MT5_PID_CONTINUITY=PASS"
    Write-Host "WORKER=OFF"
    Write-Host "LIVE_TRADING=OFF"
    Write-Host "MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"
    Write-Host "DEMO_ORDER_SENT=False"
    Write-Host "===================================================="
}
catch {
    Write-Host ""
    Write-Host "STEP18_DEPLOYMENT_FAILURE=$($_.Exception.Message)"
    Write-Host "STEP18_ROLLBACK_START=True"

    Copy-Item `
        -Path $wrapperBackup `
        -Destination $appFile `
        -Force

    & $pythonExe -m py_compile $appFile

    Stop-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2

    Start-ScheduledTask `
        -TaskName $taskName `
        -ErrorAction SilentlyContinue

    Write-Host "STEP18_SOURCE_ROLLBACK=PASS"
    Write-Host "STEP18_BRIDGE_RESTART_AFTER_ROLLBACK=REQUESTED"
    throw
}
