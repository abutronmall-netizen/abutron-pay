param(
    [ValidateSet("BUY","SELL")]
    [string]$Direction = "BUY"
)

$ErrorActionPreference = "Stop"

$root       = "C:\Abutron\TradingPlatformV4"
$envFile    = "$root\.env"
$pythonExe  = "$root\.venv\Scripts\python.exe"
$helper     = "$root\scripts\step18_management_lifecycle_cert_v2.py"
$appFile    = "$root\mt5_bridge\app.py"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

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

    if ($exec.ToLowerInvariant() -ne "false") { throw "ABUTRON_EXECUTION_ENABLED must remain false." }
    if ($live.ToLowerInvariant() -ne "false") { throw "MT5_LIVE_TRADING must remain false." }
    if ($mgmt.ToLowerInvariant() -ne "false") { throw "MT5_MANAGEMENT_ENABLED must remain false." }
    if ($demo.ToLowerInvariant() -ne "true") { throw "MT5_DEMO_ONLY must remain true." }
    if (@(Get-WorkerProcesses).Count -ne 0) { throw "Trading worker must remain OFF." }
}

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 18 V2"
Write-Host " POSITION MANAGEMENT / BE / TRAILING / OWNERSHIP"
Write-Host " CLOSE LIFECYCLE CERTIFICATION"
Write-Host " IC MARKETS DEMO ONLY"
Write-Host "===================================================="

foreach ($required in @($envFile,$pythonExe,$helper,$appFile,$mt5Path)) {
    if (-not (Test-Path $required)) { throw "Missing Step 18 prerequisite: $required" }
}

Confirm-Safety

$corePid   = Get-ListenerPid 8088
$bridgePid = Get-ListenerPid 8090
$jarvisPid = Get-ListenerPid 8787

if (-not $corePid -or -not $bridgePid -or -not $jarvisPid) {
    throw "Core/Bridge/Jarvis baseline listener missing."
}

$coreHealth = Invoke-RestMethod -Uri "http://127.0.0.1:8088/health" -TimeoutSec 30
$bridgeHealth = Invoke-RestMethod -Uri "http://127.0.0.1:8090/health" -TimeoutSec 30

if ($coreHealth.status -ne "ok" -or $coreHealth.kronos_loaded -ne $true -or $coreHealth.execution_enabled -ne $false) {
    throw "Core/Kronos baseline failed."
}

if ($bridgeHealth.status -ne "ok" -or $bridgeHealth.mt5_connected -ne $true -or $bridgeHealth.live_trading -ne $false -or $bridgeHealth.management_enabled -ne $false) {
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
        throw "Step18 management hardening is not installed: $marker"
    }
}

Write-Host "STEP18_SAFETY_BASELINE=PASS"
Write-Host "STEP18_MANAGEMENT_HARDENING_PRESENT=PASS"
Write-Host "KRONOS_LOADED=True"
Write-Host "WORKER=OFF"
Write-Host "PRODUCTION_LIVE_TRADING=OFF"
Write-Host "PRODUCTION_MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"

& $pythonExe -m py_compile $helper
if ($LASTEXITCODE -ne 0) { throw "Step18 helper Python syntax failed." }

Write-Host "STEP18_HELPER_SYNTAX=PASS"

$helperText = Get-Content $helper -Raw

foreach ($marker in @(
    "STEP18_CERT_V2_EXACT_DEMO_IDENTITY",
    "STEP18_CERT_V2_EXACT_IDENTITY_REPAIR = True"
)) {
    if ($helperText -notmatch [regex]::Escape($marker)) {
        throw "Step18 certification helper V2 marker missing: $marker"
    }
}

Write-Host "STEP18_CERT_V2_IDENTITY_HARNESS=PASS"

Write-Host ""
Write-Host "--- STEP 18 CONTROLLED DEMO CERTIFICATION ---"
Write-Host "CERTIFICATION_DIRECTION=$Direction"
Write-Host "MARKET_RECOMMENDATION=False"

$previousErrorActionPreference = $ErrorActionPreference

try {
    $ErrorActionPreference = "Continue"
    $output = @(
        & $pythonExe `
            $helper `
            --mt5-path $mt5Path `
            --symbol XAUUSD `
            --direction $Direction 2>&1
    )
    $childExit = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

foreach ($line in $output) { Write-Host ([string]$line) }

if ($childExit -ne 0) {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 18 = NOT CERTIFIED"
    Write-Host "===================================================="
    Write-Host "DO_NOT_RERUN=True"
    Write-Host "UPLOAD_NEWEST_LOG=True"
    throw "Step18 helper returned exit code $childExit."
}

$values = @{}
foreach ($line in $output) {
    $text = [string]$line
    if ($text -match '^([A-Z0-9_]+)=(.*)$') {
        $values[$matches[1]] = $matches[2]
    }
}

$requiredPasses = @(
    "STEP18_MANAGEMENT_HARDENING_STATIC",
    "DEMO_ACCOUNT_IDENTITY",
    "ZERO_POSITION_BASELINE",
    "MANAGEMENT_DISABLED_REFUSAL",
    "DETERMINISTIC_BREAK_EVEN_POLICY",
    "DETERMINISTIC_OWNERSHIP_ISOLATION",
    "DETERMINISTIC_TRAILING_POLICY",
    "DETERMINISTIC_NO_WORSENING_SL",
    "DETERMINISTIC_STOPS_FREEZE_GUARD",
    "DETERMINISTIC_SLTP_ORDER_CHECK",
    "DETERMINISTIC_NO_IMPROVEMENT_NO_SEND",
    "DETERMINISTIC_CLOSE_OWNERSHIP_REFUSAL",
    "REAL_DEMO_OPEN",
    "REAL_POSITION_OWNERSHIP",
    "REAL_BROKER_SLTP_MANAGEMENT",
    "REAL_BROKER_STOPS_FREEZE_PATH",
    "REAL_NO_WORSENING_SL",
    "REAL_REPEATED_MANAGE_NO_WORSENING",
    "REAL_NORMAL_CLOSE",
    "TERMINAL_HISTORY_CLOSE_AGREEMENT",
    "ZERO_RESIDUAL_EXPOSURE",
    "POSITION_METADATA_CLEANUP",
    "PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED",
    "TEMP_CERTIFICATION_STORE_REMOVED",
    "PROCESS_LOCAL_SETTINGS_RESTORED",
    "STEP_18_HELPER",
    "MANAGED_GATE",
    "CLOSED_GATE"
)

foreach ($name in $requiredPasses) {
    if ($values[$name] -ne "PASS") {
        throw "Missing Step18 PASS gate: $name"
    }
}

Confirm-Safety

if ((Get-ListenerPid 8088) -ne $corePid) { throw "Core PID changed during Step18." }
if ((Get-ListenerPid 8090) -ne $bridgePid) { throw "Production Bridge PID changed during Step18." }
if ((Get-ListenerPid 8787) -ne $jarvisPid) { throw "Jarvis PID changed during Step18." }

$coreFinal = Invoke-RestMethod -Uri "http://127.0.0.1:8088/health" -TimeoutSec 30
$bridgeFinal = Invoke-RestMethod -Uri "http://127.0.0.1:8090/health" -TimeoutSec 30

if ($coreFinal.status -ne "ok" -or $coreFinal.kronos_loaded -ne $true -or $coreFinal.execution_enabled -ne $false) {
    throw "Core/Kronos continuity failed."
}

if ($bridgeFinal.status -ne "ok" -or $bridgeFinal.mt5_connected -ne $true -or $bridgeFinal.live_trading -ne $false -or $bridgeFinal.management_enabled -ne $false) {
    throw "Production Bridge final safety state failed."
}

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 18 = PASS"
Write-Host "===================================================="
Write-Host "MANAGED_GATE=PASS"
Write-Host "CLOSED_GATE=PASS"
Write-Host "BREAK_EVEN_POLICY=PASS"
Write-Host "TRAILING_POLICY=PASS"
Write-Host "OWNERSHIP_ISOLATION=PASS"
Write-Host "STOPS_FREEZE_GUARD=PASS"
Write-Host "NO_WORSENING_SL=PASS"
Write-Host "REAL_BROKER_SLTP_MANAGEMENT=PASS"
Write-Host "REAL_NORMAL_CLOSE=PASS"
Write-Host "TERMINAL_HISTORY_CLOSE_AGREEMENT=PASS"
Write-Host "ZERO_RESIDUAL_EXPOSURE=PASS"
Write-Host "CORE_PID_CONTINUITY=PASS"
Write-Host "BRIDGE_PID_CONTINUITY=PASS"
Write-Host "JARVIS_PID_CONTINUITY=PASS"
Write-Host "KRONOS_LOADED=True"
Write-Host "WORKER=OFF"
Write-Host "PRODUCTION_LIVE_TRADING=OFF"
Write-Host "PRODUCTION_MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "LIVE_MONEY_AUTHORIZED=False"
Write-Host "STEP18_CHILD_EXIT=0"
Write-Host "===================================================="
