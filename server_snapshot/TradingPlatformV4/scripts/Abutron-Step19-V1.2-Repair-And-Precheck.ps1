$ErrorActionPreference = "Stop"

$root      = "C:\Abutron\TradingPlatformV4"
$scriptDir = "$root\scripts"
$pythonExe = "$root\.venv\Scripts\python.exe"
$helper    = "$scriptDir\step19_equity_router_bot_lifecycle_cert.py"
$runner    = "$scriptDir\Abutron-Step19-Equity-Router-Bot-Lifecycle-Cert.ps1"
$envFile   = "$root\.env"

$expectedHelperHash = "11BE874DD10030BF57F6981068FA8A27F0525C440AD78611F2EB8DD789ABC675"

function Fail {
    param([string]$Message)

    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 19 V1.2 PRECHECK = FAILED"
    Write-Host "===================================================="
    Write-Host "ERROR=$Message"
    Write-Host "DEMO_ORDER_SENT=False"
    Write-Host "DO_NOT_RUN_DEMO=True"
    Write-Host "===================================================="

    exit 1
}

function Get-EnvValue {
    param([string]$Name)

    $escaped = [regex]::Escape($Name)

    $line = Get-Content $envFile |
        Where-Object {
            $_ -match "^\s*$escaped\s*="
        } |
        Select-Object -First 1

    if (-not $line) {
        return $null
    }

    return (($line -split "=",2)[1]).Trim().Trim('"').Trim("'")
}

try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " ABUTRON STEP 19 V1.2"
    Write-Host " REPAIR RUNNER + VALIDATE + PRECHECK"
    Write-Host " NO BROKER EXECUTION"
    Write-Host "===================================================="

    foreach ($required in @(
        $pythonExe,
        $helper,
        $runner,
        $envFile
    )) {
        if (-not (Test-Path $required)) {
            throw "Missing Step19 prerequisite: $required"
        }
    }

    # ---------------------------------------------------------
    # SAFETY FIRST
    # ---------------------------------------------------------

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

    $workers = @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -match "(?i)(-m\s+abutron\.worker|abutron\\worker\.py)"
        }
    )

    if ($workers.Count -ne 0) {
        throw "Trading worker must remain OFF."
    }

    Write-Host "STEP19_V1_2_SAFETY=PASS"
    Write-Host "WORKER=OFF"
    Write-Host "LIVE_TRADING=OFF"
    Write-Host "MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"
    Write-Host "DEMO_ONLY=True"

    # ---------------------------------------------------------
    # HELPER INTEGRITY
    # ---------------------------------------------------------

    $helperHash = (
        Get-FileHash $helper -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($helperHash -ne $expectedHelperHash) {
        throw "Python helper SHA256 mismatch: $helperHash"
    }

    & $pythonExe -m py_compile $helper

    if ($LASTEXITCODE -ne 0) {
        throw "Python helper syntax failed."
    }

    Write-Host "STEP19_HELPER_HASH=PASS"
    Write-Host "STEP19_HELPER_SYNTAX=PASS"

    # ---------------------------------------------------------
    # REPAIR THE RUNNER SEMANTICALLY IF NEEDED
    # ---------------------------------------------------------

    $runnerText = Get-Content $runner -Raw
    $backup = "$runner.before-step19-v1.2.bak"

    if (
        $runnerText -notmatch 'STEP19_HELPER_MODE=' -or
        $runnerText -notmatch '\$helperMode\s*=' -or
        $runnerText -notmatch '"preflight"'
    ) {
        Copy-Item $runner $backup -Force
        Write-Host "STEP19_RUNNER_BACKUP=$backup"

        $oldBlock = @'
$argsList = @(
    $helper,
    "--mode", $Mode.ToLowerInvariant(),
    "--direction", $Direction,
    "--require-tier", $RequireTier,
    "--mt5-path", $mt5Path
)
'@

        $newBlock = @'
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
'@

        if (-not $runnerText.Contains($oldBlock)) {
            throw "Runner needs repair, but the known V1 mode block was not found. No automatic edit applied."
        }

        $runnerText = $runnerText.Replace(
            $oldBlock,
            $newBlock
        )

        Set-Content `
            -Path $runner `
            -Value $runnerText `
            -Encoding UTF8 `
            -NoNewline

        Write-Host "STEP19_RUNNER_MODE_REPAIR=APPLIED"
    }
    else {
        Write-Host "STEP19_RUNNER_MODE_REPAIR=ALREADY_PRESENT"
    }

    # ---------------------------------------------------------
    # VALIDATE REPAIRED RUNNER
    # ---------------------------------------------------------

    $runnerText = Get-Content $runner -Raw

    foreach ($marker in @(
        'STEP19_HELPER_MODE=',
        '$helperMode',
        '"preflight"',
        '"demo"',
        '-AuthorizeDemo'
    )) {
        if ($runnerText -notmatch [regex]::Escape($marker)) {
            throw "Runner semantic marker missing: $marker"
        }
    }

    if (
        $runnerText -match '"--mode",\s*\$Mode\.ToLowerInvariant\(\)'
    ) {
        throw "Old PRECHECK -> precheck bug still exists in runner."
    }

    $tokens = $null
    $parseErrors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $runner,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        foreach ($item in $parseErrors) {
            Write-Host "PARSER_ERROR=$($item.Message)"
        }

        throw "Repaired Step19 runner PowerShell syntax failed."
    }

    Write-Host "STEP19_RUNNER_SEMANTIC_VALIDATION=PASS"
    Write-Host "STEP19_RUNNER_SYNTAX=PASS"

    # ---------------------------------------------------------
    # RUN ONLY PRECHECK
    # ---------------------------------------------------------

    Write-Host ""
    Write-Host "--- STARTING STEP19 PRECHECK ONLY ---"

    $previous = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        $output = @(
            & powershell.exe `
                -NoProfile `
                -ExecutionPolicy Bypass `
                -File $runner `
                -Mode PRECHECK `
                -RequireTier ANY 2>&1
        )

        $childExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    foreach ($line in $output) {
        Write-Host ([string]$line)
    }

    Write-Host ""
    Write-Host "STEP19_V1_2_CHILD_EXIT=$childExit"

    if ($childExit -ne 0) {
        throw "Step19 PRECHECK child returned exit code $childExit."
    }

    $values = @{}

    foreach ($line in $output) {
        $text = [string]$line

        if ($text -match '^([A-Z0-9_]+)=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }

    $requiredPasses = @(
        "DETERMINISTIC_FLIPPER_ROUTE",
        "DETERMINISTIC_FLIPPER_PROFILE",
        "DETERMINISTIC_FLIPPER_STRATEGY",
        "DETERMINISTIC_FLIPPER_RISK",
        "DETERMINISTIC_FLIPPER_CAPITAL",
        "DETERMINISTIC_SCALPER_ROUTE",
        "DETERMINISTIC_SCALPER_PROFILE",
        "DETERMINISTIC_SCALPER_STRATEGY",
        "DETERMINISTIC_SCALPER_RISK",
        "DETERMINISTIC_SCALPER_CAPITAL",
        "DETERMINISTIC_MASTER_ROUTE",
        "DETERMINISTIC_MASTER_PROFILE",
        "DETERMINISTIC_MASTER_STRATEGY",
        "DETERMINISTIC_MASTER_RISK",
        "DETERMINISTIC_MASTER_CAPITAL",
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
        "STEP19_PREFLIGHT",
        "STEP19_BUILD_PRECHECK"
    )

    foreach ($name in $requiredPasses) {
        if ($values[$name] -ne "PASS") {
            throw "Missing genuine Step19 PRECHECK PASS: $name"
        }
    }

    if ($values["DEMO_ORDER_SENT"] -ne "False") {
        throw "Unexpected DEMO_ORDER_SENT value."
    }

    # ---------------------------------------------------------
    # SAFETY AFTER PRECHECK
    # ---------------------------------------------------------

    $exec2 = [string](Get-EnvValue "ABUTRON_EXECUTION_ENABLED")
    $live2 = [string](Get-EnvValue "MT5_LIVE_TRADING")
    $mgmt2 = [string](Get-EnvValue "MT5_MANAGEMENT_ENABLED")
    $demo2 = [string](Get-EnvValue "MT5_DEMO_ONLY")

    if (
        $exec2.ToLowerInvariant() -ne "false" -or
        $live2.ToLowerInvariant() -ne "false" -or
        $mgmt2.ToLowerInvariant() -ne "false" -or
        $demo2.ToLowerInvariant() -ne "true"
    ) {
        throw "Production safety locks changed during Step19 precheck."
    }

    if (@(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.CommandLine -match "(?i)(-m\s+abutron\.worker|abutron\\worker\.py)"
        }
    ).Count -ne 0) {
        throw "Worker appeared during Step19 precheck."
    }

    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 19 V1.2 PRECHECK = PASS"
    Write-Host "===================================================="
    Write-Host "STEP19_V1_2_PRECHECK=PASS"
    Write-Host "ACTUAL_SELECTED_TIER=$($values['ACTUAL_SELECTED_TIER'])"
    Write-Host "WORKER=OFF"
    Write-Host "PRODUCTION_LIVE_TRADING=OFF"
    Write-Host "PRODUCTION_MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"
    Write-Host "DEMO_ORDER_SENT=False"
    Write-Host "STEP19_DEMO_AUTHORIZED=False"
    Write-Host "LIVE_MONEY_AUTHORIZED=False"
    Write-Host "NEXT_ACTION=UPLOAD_THIS_OUTPUT"
    Write-Host "===================================================="

    exit 0
}
catch {
    Fail $_.Exception.Message
}
