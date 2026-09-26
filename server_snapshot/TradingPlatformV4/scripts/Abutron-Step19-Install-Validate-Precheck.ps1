$ErrorActionPreference = "Stop"

$root      = "C:\Abutron\TradingPlatformV4"
$scriptDir = "$root\scripts"
$pythonExe = "$root\.venv\Scripts\python.exe"
$helper    = "$scriptDir\step19_equity_router_bot_lifecycle_cert.py"
$runner    = "$scriptDir\Abutron-Step19-Equity-Router-Bot-Lifecycle-Cert.ps1"
$envFile   = "$root\.env"

$expectedHelperHash = "11BE874DD10030BF57F6981068FA8A27F0525C440AD78611F2EB8DD789ABC675"
$expectedRunnerHash = "2F3D5C680D23842C80D32E1F734FBA1035A42D054DB88BC67C654CA77AD03EFA"

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

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 19 - INSTALL / VALIDATE / PRECHECK"
Write-Host " READ-ONLY WITH RESPECT TO BROKER EXECUTION"
Write-Host "===================================================="

foreach ($required in @(
    $pythonExe,
    $helper,
    $runner,
    $envFile
)) {
    if (-not (Test-Path $required)) {
        throw "Missing Step19 file: $required"
    }
}

$helperHash = (Get-FileHash $helper -Algorithm SHA256).Hash.ToUpperInvariant()
$runnerHash = (Get-FileHash $runner -Algorithm SHA256).Hash.ToUpperInvariant()

if ($helperHash -ne $expectedHelperHash) {
    throw "Step19 helper SHA256 mismatch."
}

if ($runnerHash -ne $expectedRunnerHash) {
    throw "Step19 runner SHA256 mismatch."
}

Write-Host "STEP19_FILE_HASHES=PASS"

& $pythonExe -m py_compile $helper

if ($LASTEXITCODE -ne 0) {
    throw "Step19 Python helper syntax failed."
}

Write-Host "STEP19_PYTHON_SYNTAX=PASS"

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

    throw "Step19 PowerShell runner syntax failed."
}

Write-Host "STEP19_POWERSHELL_SYNTAX=PASS"

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

Write-Host "STEP19_PRODUCTION_SAFETY=PASS"
Write-Host "WORKER=OFF"
Write-Host "LIVE_TRADING=OFF"
Write-Host "MANAGEMENT=OFF"
Write-Host "ABUTRON_EXECUTION=OFF"
Write-Host "DEMO_ONLY=True"

Write-Host ""
Write-Host "--- STARTING STEP19 PRECHECK ONLY ---"

& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $runner `
    -Mode PRECHECK `
    -RequireTier ANY

$exitCode = $LASTEXITCODE

Write-Host ""
Write-Host "STEP19_PRECHECK_CHILD_EXIT=$exitCode"

if ($exitCode -ne 0) {
    throw "Step19 PRECHECK failed. No DEMO lifecycle should be run."
}

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 19 INSTALLATION + PRECHECK = PASS"
Write-Host "===================================================="
Write-Host "NO_STEP19_DEMO_ORDER_AUTHORIZED=True"
Write-Host "NEXT_ACTION=UPLOAD_PRECHECK_LOG"
Write-Host "===================================================="
