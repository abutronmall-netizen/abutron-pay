param(
    [ValidateSet("PRECHECK","DEMO")]
    [string]$Mode = "PRECHECK",

    [ValidateSet("ANY","FLIPPER","SCALPER","MASTER")]
    [string]$RequireTier = "ANY",

    [ValidateSet("BUY","SELL")]
    [string]$Direction = "BUY",

    [switch]$AuthorizeDemo
)

$ErrorActionPreference = "Stop"

$root      = "C:\Abutron\TradingPlatformV4"
$envFile   = "$root\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"
$helper    = "$root\scripts\step19_equity_router_bot_lifecycle_cert.py"
$appFile   = "$root\mt5_bridge\app.py"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

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

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 19"
Write-Host " EQUITY ROUTER -> BOT -> BROKER -> DB LIFECYCLE"
Write-Host " MODE=$Mode"
Write-Host " IC MARKETS DEMO ONLY"
Write-Host "===================================================="

foreach ($required in @(
    $envFile,
    $pythonExe,
    $helper,
    $appFile,
    $mt5Path
)) {
    if (-not (Test-Path $required)) {
        throw "Missing Step19 prerequisite: $required"
    }
}

Confirm-Safety

$corePid   = Get-ListenerPid 8088
$bridgePid = Get-ListenerPid 8090
$jarvisPid = Get-ListenerPid 8787

if (-not $corePid -or -not $bridgePid -or -not $jarvisPid) {
    throw "Core/Bridge/Jarvis baseline listener missing."
}

$coreHealth = Invoke-RestMethod `
    -Uri "http://127.0.0.1:8088/health" `
    -TimeoutSec 30

$bridgeHealth = Invoke-RestMethod `
    -Uri "http://127.0.0.1:8090/health" `
    -TimeoutSec 30

if (
    $coreHealth.status -ne "ok" -or
    $coreHealth.kronos_loaded -ne $true -or
    $coreHealth.execution_enabled -ne $false
) {
    throw "Core/Kronos baseline failed."
}

if (
    $bridgeHealth.status -ne "ok" -or
    $bridgeHealth.mt5_connected -ne $true -or
    $bridgeHealth.live_trading -ne $false -or
    $bridgeHealth.management_enabled -ne $false
) {
    throw "Production Bridge safety baseline failed."
}

$appText = Get-Content $appFile -Raw

foreach ($marker in @(
    "STEP18_MANAGEMENT_HARDENING_V1",
    "trade_stops_level",
    "trade_freeze_level",
    "MANAGE_ORDER_CHECK_REJECTED"
)) {
    if ($appText -notmatch [regex]::Escape($marker)) {
        throw "Step18 management hardening prerequisite missing: $marker"
    }
}

& $pythonExe -m py_compile $helper

if ($LASTEXITCODE -ne 0) {
    throw "Step19 helper Python syntax failed."
}

$helperText = Get-Content $helper -Raw

foreach ($marker in @(
    "STEP19_EQUITY_ROUTER_BOT_LIFECYCLE_V1",
    "DETERMINISTIC_ALL_TIER_CONTRACTS",
    "BROKER_POSITION_TIER_ATTESTATION",
    "DATABASE_CLOSED_TIER_RECONCILIATION",
    "STEP19_ALL_THREE_BOTS_CERTIFIED"
)) {
    if ($helperText -notmatch [regex]::Escape($marker)) {
        throw "Step19 helper marker missing: $marker"
    }
}

if (
    $Mode -eq "DEMO" -and
    -not $AuthorizeDemo
) {
    throw "DEMO mode requires explicit -AuthorizeDemo."
}

Write-Host "STEP19_SAFETY_BASELINE=PASS"
Write-Host "STEP19_HELPER_SYNTAX=PASS"
Write-Host "STEP19_HELPER_STATIC=PASS"
Write-Host "STEP18_MANAGEMENT_PREREQUISITE=PASS"
Write-Host "KRONOS_LOADED=True"
Write-Host "WORKER=OFF"
Write-Host "PRODUCTION_LIVE_TRADING=OFF"
Write-Host "PRODUCTION_MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"

$helperMode = if ($Mode -eq "PRECHECK") {
    "preflight"
}
else {
    "demo"
}

Write-Host "STEP19_HELPER_MODE=$helperMode"

$argsList = @(
    $helper,
    "--mode", $helperMode,
    "--direction", $Direction,
    "--require-tier", $RequireTier,
    "--mt5-path", $mt5Path
)

$previousErrorActionPreference = $ErrorActionPreference

try {
    $ErrorActionPreference = "Continue"

    $output = @(
        & $pythonExe @argsList 2>&1
    )

    $childExit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

foreach ($line in $output) {
    Write-Host ([string]$line)
}

Write-Host ""
Write-Host "STEP19_CHILD_EXIT=$childExit"

if ($childExit -ne 0) {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 19 RUN = NOT CERTIFIED"
    Write-Host "===================================================="

    if ($Mode -eq "DEMO") {
        Write-Host "DO_NOT_RERUN=True"
        Write-Host "UPLOAD_NEWEST_LOG=True"
    }

    throw "Step19 helper returned exit code $childExit."
}

$values = @{}

foreach ($line in $output) {
    $text = [string]$line

    if ($text -match '^([A-Z0-9_]+)=(.*)$') {
        $values[$matches[1]] = $matches[2]
    }
}

$precheckPasses = @(
    "DETERMINISTIC_ALL_TIER_CONTRACTS",
    "DETERMINISTIC_STICKY_TIER_LOCK",
    "DEMO_ACCOUNT_IDENTITY",
    "ACTUAL_EQUITY_ROUTE",
    "EXACT_PLATFORM_ACCOUNT_BINDING",
    "LIVE_STACK_ROUTE_ATTESTATION",
    "LIVE_STACK_STRATEGY_ATTESTATION",
    "ZERO_SYMBOL_POSITION_BASELINE",
    "ZERO_SYMBOL_PENDING_ORDER_BASELINE",
    "ZERO_ABUTRON_POSITION_BASELINE",
    "STEP19_PREFLIGHT"
)

foreach ($name in $precheckPasses) {
    if ($values[$name] -ne "PASS") {
        throw "Missing Step19 precheck PASS gate: $name"
    }
}

if ($Mode -eq "PRECHECK") {
    if ($values["STEP19_BUILD_PRECHECK"] -ne "PASS") {
        throw "Step19 build precheck did not PASS."
    }

    if ($values["DEMO_ORDER_SENT"] -ne "False") {
        throw "Unexpected Step19 DEMO-order flag during precheck."
    }
}
else {
    $demoPasses = @(
        "ACTUAL_TIER_RISK_ENGINE",
        "ACTUAL_TIER_CAPITAL_ENGINE",
        "PLAN_TIER_PROFILE_ALIGNMENT",
        "BROKER_TIER_COMMENT_PRECHECK",
        "BROKER_MINIMUM_VOLUME_ONLY",
        "BROKER_ORDER_CHECK",
        "REAL_DEMO_OPEN",
        "BROKER_POSITION_TIER_ATTESTATION",
        "POSITION_TICKET_RECONCILIATION",
        "DATABASE_EXECUTION_TIER_PERSISTENCE",
        "DATABASE_CURRENT_TIER_ASSIGNMENT",
        "ACTUAL_TIER_REAL_MANAGEMENT",
        "ACTUAL_TIER_NO_WORSENING_SL",
        "ACTUAL_TIER_NORMAL_CLOSE",
        "DATABASE_RECONCILIATION_IDEMPOTENT",
        "DATABASE_CLOSED_TIER_RECONCILIATION",
        "BROKER_DATABASE_POSITION_AGREEMENT",
        "ZERO_RESIDUAL_EXPOSURE",
        "POSITION_METADATA_CLEANUP",
        "STEP19_SELECTED_TIER_LIFECYCLE",
        "PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED",
        "TEMP_CERTIFICATION_STORE_REMOVED",
        "PROCESS_LOCAL_SETTINGS_RESTORED"
    )

    foreach ($name in $demoPasses) {
        if ($values[$name] -ne "PASS") {
            throw "Missing Step19 DEMO PASS gate: $name"
        }
    }
}

Confirm-Safety

if ((Get-ListenerPid 8088) -ne $corePid) {
    throw "Core PID changed during Step19."
}

if ((Get-ListenerPid 8090) -ne $bridgePid) {
    throw "Production Bridge PID changed during Step19."
}

if ((Get-ListenerPid 8787) -ne $jarvisPid) {
    throw "Jarvis PID changed during Step19."
}

$coreFinal = Invoke-RestMethod `
    -Uri "http://127.0.0.1:8088/health" `
    -TimeoutSec 30

$bridgeFinal = Invoke-RestMethod `
    -Uri "http://127.0.0.1:8090/health" `
    -TimeoutSec 30

if (
    $coreFinal.status -ne "ok" -or
    $coreFinal.kronos_loaded -ne $true -or
    $coreFinal.execution_enabled -ne $false
) {
    throw "Core/Kronos continuity failed."
}

if (
    $bridgeFinal.status -ne "ok" -or
    $bridgeFinal.mt5_connected -ne $true -or
    $bridgeFinal.live_trading -ne $false -or
    $bridgeFinal.management_enabled -ne $false
) {
    throw "Production Bridge final safety state failed."
}

Write-Host ""
Write-Host "===================================================="

if ($Mode -eq "PRECHECK") {
    Write-Host " STEP 19 BUILD PRECHECK = PASS"
}
elseif ($values["STEP_19"] -eq "PASS") {
    Write-Host " STEP 19 = PASS"
}
else {
    Write-Host " STEP 19 SELECTED-TIER LIFECYCLE = PASS"
    Write-Host " STEP 19 FULL THREE-BOT CERTIFICATION = PENDING"
}

Write-Host "===================================================="
Write-Host "ACTUAL_SELECTED_TIER=$($values['ACTUAL_SELECTED_TIER'])"

if ($Mode -eq "DEMO") {
    Write-Host "STEP19_CERTIFIED_TIER=$($values['STEP19_CERTIFIED_TIER'])"
    Write-Host "STEP19_CERTIFIED_TIER_COUNT=$($values['STEP19_CERTIFIED_TIER_COUNT'])"
    Write-Host "STEP19_ALL_THREE_BOTS_CERTIFIED=$($values['STEP19_ALL_THREE_BOTS_CERTIFIED'])"
}

Write-Host "CORE_PID_CONTINUITY=PASS"
Write-Host "BRIDGE_PID_CONTINUITY=PASS"
Write-Host "JARVIS_PID_CONTINUITY=PASS"
Write-Host "KRONOS_LOADED=True"
Write-Host "WORKER=OFF"
Write-Host "PRODUCTION_LIVE_TRADING=OFF"
Write-Host "PRODUCTION_MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "LIVE_MONEY_AUTHORIZED=False"
Write-Host "STEP19_CHILD_EXIT=0"
Write-Host "===================================================="
