param(
    [ValidateSet("PRECHECK","DEMO")]
    [string]$Mode = "PRECHECK",

    [ValidateSet("SCALPER","MASTER")]
    [string]$RequireTier,

    [Parameter(Mandatory=$true)]
    [string]$CertLogin,

    [ValidateSet("BUY","SELL")]
    [string]$Direction = "BUY",

    [switch]$AuthorizeDemo
)

$ErrorActionPreference = "Stop"

$root      = "C:\Abutron\TradingPlatformV4"
$envFile   = "$root\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"
$helper    = "$root\scripts\step19_multi_demo_cert_v1_3.py"
$appFile   = "$root\mt5_bridge\app.py"
$mt5Path   = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$expectedHelperHash = "14ACC5D402ED885448FD8762240E915976AEEB4AABFA2B8FC19DAD8C908C4EF3"

function Get-EnvValue {
    param([string]$Name)

    $escaped = [regex]::Escape($Name)
    $line = Get-Content $envFile |
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

function Get-WorkerProcesses {
    return @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -match "(?i)(-m\s+abutron\.worker|abutron\\worker\.py)"
        }
    )
}

function Confirm-Safety {
    $exec = [string](Get-EnvValue "ABUTRON_EXECUTION_ENABLED")
    $live = [string](Get-EnvValue "MT5_LIVE_TRADING")
    $mgmt = [string](Get-EnvValue "MT5_MANAGEMENT_ENABLED")
    $demo = [string](Get-EnvValue "MT5_DEMO_ONLY")

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
Write-Host " ABUTRON STEP 19 MULTI-DEMO CERT V1.3"
Write-Host " MODE=$Mode TARGET=$RequireTier"
Write-Host " PROCESS-LOCAL DEMO IDENTITY OVERRIDE ONLY"
Write-Host "===================================================="

foreach ($required in @(
    $envFile,
    $pythonExe,
    $helper,
    $appFile,
    $mt5Path
)) {
    if (-not (Test-Path $required)) {
        throw "Missing Step19 V1.3 prerequisite: $required"
    }
}

if ($CertLogin -notmatch '^\d+$') {
    throw "CertLogin must contain digits only."
}

Confirm-Safety

$helperHash = (Get-FileHash $helper -Algorithm SHA256).Hash.ToUpperInvariant()

if ($helperHash -ne $expectedHelperHash) {
    throw "Step19 V1.3 helper SHA256 mismatch."
}

& $pythonExe -m py_compile $helper

if ($LASTEXITCODE -ne 0) {
    throw "Step19 V1.3 helper Python syntax failed."
}

$appText = Get-Content $appFile -Raw

foreach ($marker in @(
    "STEP18_MANAGEMENT_HARDENING_V1",
    "trade_stops_level",
    "trade_freeze_level",
    "MANAGE_ORDER_CHECK_REJECTED"
)) {
    if ($appText -notmatch [regex]::Escape($marker)) {
        throw "Step18 management prerequisite missing: $marker"
    }
}

$corePid   = Get-ListenerPid 8088
$bridgePid = Get-ListenerPid 8090
$jarvisPid = Get-ListenerPid 8787

if (-not $corePid -or -not $bridgePid -or -not $jarvisPid) {
    throw "Core/Bridge/Jarvis listener baseline missing."
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

if ($Mode -eq "DEMO" -and -not $AuthorizeDemo) {
    throw "DEMO mode requires explicit -AuthorizeDemo."
}

$helperMode = if ($Mode -eq "PRECHECK") {
    "preflight"
}
else {
    "demo"
}

Write-Host "STEP19_V1_3_SAFETY=PASS"
Write-Host "STEP19_V1_3_HELPER_HASH=PASS"
Write-Host "STEP19_V1_3_HELPER_SYNTAX=PASS"
Write-Host "STEP19_V1_3_HELPER_MODE=$helperMode"
Write-Host "CERT_LOGIN_PRINTED=False"
Write-Host "WORKER=OFF"
Write-Host "PRODUCTION_LIVE_TRADING=OFF"
Write-Host "PRODUCTION_MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"

$argsList = @(
    $helper,
    "--mode", $helperMode,
    "--require-tier", $RequireTier,
    "--direction", $Direction,
    "--cert-login", $CertLogin,
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
Write-Host "STEP19_V1_3_CHILD_EXIT=$childExit"

if ($childExit -ne 0) {
    Write-Host "STEP19_V1_3=NOT_CERTIFIED"

    if ($Mode -eq "DEMO") {
        Write-Host "DO_NOT_RERUN=True"
        Write-Host "UPLOAD_NEWEST_LOG=True"
    }

    exit $childExit
}

$values = @{}

foreach ($line in $output) {
    $text = [string]$line

    if ($text -match '^([A-Z0-9_]+)=(.*)$') {
        $values[$matches[1]] = $matches[2]
    }
}

$requiredPreflight = @(
    "CERT_CONNECTED_LOGIN_MATCH",
    "CERT_CONNECTED_SERVER_MATCH",
    "CERT_ACCOUNT_DEMO_MODE",
    "DETERMINISTIC_ALL_TIER_CONTRACTS",
    "DETERMINISTIC_STICKY_TIER_LOCK",
    "DEMO_ACCOUNT_IDENTITY",
    "ACTUAL_EQUITY_ROUTE",
    "ZERO_SYMBOL_POSITION_BASELINE",
    "ZERO_SYMBOL_PENDING_ORDER_BASELINE",
    "ZERO_ABUTRON_POSITION_BASELINE",
    "EXACT_PLATFORM_ACCOUNT_BINDING",
    "LIVE_STACK_ROUTE_ATTESTATION",
    "LIVE_STACK_STRATEGY_ATTESTATION",
    "STEP19_PREFLIGHT"
)

foreach ($name in $requiredPreflight) {
    if ($values[$name] -ne "PASS") {
        throw "Missing Step19 V1.3 preflight PASS: $name"
    }
}

if ($values["ACTUAL_SELECTED_TIER"] -ne $RequireTier) {
    throw "Actual selected tier does not match required tier."
}

if ($Mode -eq "PRECHECK") {
    if ($values["STEP19_BUILD_PRECHECK"] -ne "PASS") {
        throw "Step19 V1.3 build precheck failed."
    }

    if ($values["DEMO_ORDER_SENT"] -ne "False") {
        throw "Unexpected DEMO order flag during PRECHECK."
    }
}
else {
    $requiredDemo = @(
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

    foreach ($name in $requiredDemo) {
        if ($values[$name] -ne "PASS") {
            throw "Missing Step19 V1.3 DEMO PASS: $name"
        }
    }
}

Confirm-Safety

if ((Get-ListenerPid 8088) -ne $corePid) {
    throw "Core PID changed during Step19 V1.3."
}

if ((Get-ListenerPid 8090) -ne $bridgePid) {
    throw "Production Bridge PID changed during Step19 V1.3."
}

if ((Get-ListenerPid 8787) -ne $jarvisPid) {
    throw "Jarvis PID changed during Step19 V1.3."
}

$bridgeFinal = Invoke-RestMethod `
    -Uri "http://127.0.0.1:8090/health" `
    -TimeoutSec 30

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
    Write-Host " STEP 19 $RequireTier MULTI-DEMO PRECHECK = PASS"
}
elseif ($values["STEP_19"] -eq "PASS") {
    Write-Host " STEP 19 FULL THREE-BOT CERTIFICATION = PASS"
}
else {
    Write-Host " STEP 19 $RequireTier DEMO LIFECYCLE = PASS"
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
Write-Host "WORKER=OFF"
Write-Host "PRODUCTION_LIVE_TRADING=OFF"
Write-Host "PRODUCTION_MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "PRODUCTION_ENV_CHANGED=False"
Write-Host "LIVE_MONEY_AUTHORIZED=False"
Write-Host "STEP19_V1_3_CHILD_EXIT=0"
Write-Host "===================================================="
