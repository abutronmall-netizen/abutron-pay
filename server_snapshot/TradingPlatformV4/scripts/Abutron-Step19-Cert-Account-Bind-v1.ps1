param(
    [ValidateSet("SCALPER","MASTER")]
    [string]$RequireTier,

    [Parameter(Mandatory=$true)]
    [string]$CertLogin
)

$ErrorActionPreference = "Stop"

$root      = "C:\Abutron\TradingPlatformV4"
$pythonExe = "$root\.venv\Scripts\python.exe"
$helper    = "$root\scripts\step19_cert_account_bind_v1.py"
$mt5Path   = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"
$envFile   = "$root\.env"

$expectedHash = "1F4387276B5F3923A88D67C5CF5DA73DDAC724075C3AEF76121DD584D9980008"

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

function Fail {
    param([string]$Message)

    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 19 CERT ACCOUNT BIND = FAILED"
    Write-Host "===================================================="
    Write-Host "ERROR=$Message"
    Write-Host "DEMO_ORDER_SENT=False"
    Write-Host "DO_NOT_RUN_DEMO=True"
    Write-Host "===================================================="
    exit 1
}

try {
    foreach ($required in @(
        $pythonExe,
        $helper,
        $mt5Path,
        $envFile
    )) {
        if (-not (Test-Path $required)) {
            throw "Missing prerequisite: $required"
        }
    }

    if ($CertLogin -notmatch '^\d+$') {
        throw "CertLogin must contain digits only."
    }

    $hash = (Get-FileHash $helper -Algorithm SHA256).Hash.ToUpperInvariant()

    if ($hash -ne $expectedHash) {
        throw "Step19 account binder helper SHA256 mismatch."
    }

    & $pythonExe -m py_compile $helper

    if ($LASTEXITCODE -ne 0) {
        throw "Step19 account binder Python syntax failed."
    }

    if (
        ([string](Get-EnvValue "ABUTRON_EXECUTION_ENABLED")).ToLowerInvariant() -ne "false" -or
        ([string](Get-EnvValue "MT5_LIVE_TRADING")).ToLowerInvariant() -ne "false" -or
        ([string](Get-EnvValue "MT5_MANAGEMENT_ENABLED")).ToLowerInvariant() -ne "false" -or
        ([string](Get-EnvValue "MT5_DEMO_ONLY")).ToLowerInvariant() -ne "true"
    ) {
        throw "Production safety flags are not locked."
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

    Write-Host "STEP19_CERT_BIND_SAFETY=PASS"
    Write-Host "STEP19_CERT_BIND_HELPER_HASH=PASS"
    Write-Host "STEP19_CERT_BIND_HELPER_SYNTAX=PASS"
    Write-Host "WORKER=OFF"
    Write-Host "PRODUCTION_LIVE_TRADING=OFF"
    Write-Host "PRODUCTION_MANAGEMENT=OFF"
    Write-Host "ABUTRON_EXECUTION=OFF"

    $previous = $ErrorActionPreference

    try {
        $ErrorActionPreference = "Continue"

        $output = @(
            & $pythonExe `
                $helper `
                --cert-login $CertLogin `
                --require-tier $RequireTier `
                --mt5-path $mt5Path `
                --license-hours 72 2>&1
        )

        $childExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    foreach ($line in $output) {
        Write-Host ([string]$line)
    }

    Write-Host "STEP19_CERT_BIND_CHILD_EXIT=$childExit"

    if ($childExit -ne 0) {
        throw "Step19 certification account bind child failed."
    }

    $values = @{}

    foreach ($line in $output) {
        $text = [string]$line

        if ($text -match '^([A-Z0-9_]+)=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }

    foreach ($name in @(
        "PRODUCTION_EXECUTION_LOCKS",
        "CONNECTED_LOGIN_MATCH",
        "CONNECTED_SERVER_MATCH",
        "CONNECTED_ACCOUNT_DEMO",
        "ACTUAL_EQUITY_TIER_MATCH",
        "ZERO_OPEN_POSITIONS",
        "ZERO_PENDING_ORDERS",
        "EXACT_PLATFORM_ACCOUNT_BINDING",
        "PLATFORM_LICENSE_ACTIVE",
        "STEP19_CERT_ACCOUNT_BIND"
    )) {
        if ($values[$name] -ne "PASS") {
            throw "Missing genuine account-bind PASS: $name"
        }
    }

    if ($values["DEMO_ORDER_SENT"] -ne "False") {
        throw "Unexpected DEMO order flag."
    }

    Write-Host ""
    Write-Host "===================================================="
    Write-Host " STEP 19 $RequireTier CERT ACCOUNT BIND = PASS"
    Write-Host "===================================================="
    Write-Host "PLATFORM_LICENSE_ACTIVE=PASS"
    Write-Host "DEMO_ORDER_SENT=False"
    Write-Host "PRODUCTION_ENV_CHANGED=False"
    Write-Host "TRADING_CORE_SOURCE_CHANGED=False"
    Write-Host "NEXT_ACTION=RERUN_V1_3_PRECHECK"
    Write-Host "===================================================="
    exit 0
}
catch {
    Fail $_.Exception.Message
}
