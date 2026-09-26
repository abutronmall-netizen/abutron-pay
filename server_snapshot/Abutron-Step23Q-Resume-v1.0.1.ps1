param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$PackageRoot = "C:\Abutron\Step23Q-Package"
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogDir = "C:\Abutron\Step23Q\logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Log = Join-Path $LogDir "step23q_resume_v1_0_1_$Stamp.log"

function Log([string]$Message) {
    $line = "$(Get-Date -Format s) $Message"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

function Run-NativeChecked {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Name
    )

    $outFile = Join-Path $LogDir "$($Name)_stdout_$Stamp.log"
    $errFile = Join-Path $LogDir "$($Name)_stderr_$Stamp.log"

    $p = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -WorkingDirectory $Root `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError $errFile `
        -Wait `
        -PassThru `
        -NoNewWindow

    if (Test-Path $outFile) {
        Get-Content $outFile | ForEach-Object { Log "$Name OUT: $_" }
    }
    if (Test-Path $errFile) {
        Get-Content $errFile | ForEach-Object { Log "$Name ERR: $_" }
    }

    Log "$Name`_EXIT_CODE=$($p.ExitCode)"
    if ($p.ExitCode -ne 0) {
        throw "$Name failed with exit code $($p.ExitCode)"
    }
}

Log "STEP23Q_RESUME_V1_0_1_START"

if (-not (Test-Path $Root)) {
    throw "ROOT_NOT_FOUND=$Root"
}
if (-not (Test-Path $PackageRoot)) {
    throw "PACKAGE_ROOT_NOT_FOUND=$PackageRoot"
}

$Python = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path $Python)) {
    throw "PYTHON_NOT_FOUND=$Python"
}

# ------------------------------------------------------------------
# 1. Re-verify live-trading safety.
# ------------------------------------------------------------------
$envPath = Join-Path $Root ".env"
$envText = if (Test-Path $envPath) { Get-Content $envPath -Raw } else { "" }

foreach ($danger in @(
    "ABUTRON_EXECUTION_ENABLED=true",
    "MT5_LIVE_TRADING=true",
    "MT5_MANAGEMENT_ENABLED=true",
    "CTRADER_LIVE_EXECUTION_ENABLED=true",
    "LIVE_MONEY_AUTHORIZED=true"
)) {
    if ($envText -match [regex]::Escape($danger)) {
        throw "STEP23Q_SAFETY_ABORT=$danger"
    }
}
Log "STEP23Q_LIVE_SAFETY=PASS"

# ------------------------------------------------------------------
# 2. Confirm the partial install really reached the QME patch.
# ------------------------------------------------------------------
$quantDir = Join-Path $Root "abutron\quant"
$servicePath = Join-Path $Root "abutron\service.py"

if (-not (Test-Path $quantDir)) {
    throw "STEP23Q_QUANT_PACKAGE_MISSING"
}
if (-not (Test-Path $servicePath)) {
    throw "STEP23Q_SERVICE_MISSING"
}

$service = Get-Content $servicePath -Raw

$requiredServiceMarkers = @(
    "from abutron.quant.engine import QuantEngine",
    "self.quant=QuantEngine.from_env()",
    '"QUANTITATIVE MATHEMATICS"',
    '"quant":quant.to_dict()',
    "thesis=create_thesis(symbol,kronos,features,mode,min_conf)",
    "risk=self.risk.evaluate(thesis,account,broker,bundle,tier=tier)",
    "plan=make_order_plan(",
    "if execute and settings.execution_enabled and result.plan:"
)

foreach ($marker in $requiredServiceMarkers) {
    if (-not $service.Contains($marker)) {
        throw "STEP23Q_SERVICE_MARKER_MISSING=$marker"
    }
}
Log "STEP23Q_SERVICE_PATCH_VERIFY=PASS"

# ------------------------------------------------------------------
# 3. Force SHADOW mode only.
# ------------------------------------------------------------------
if (Test-Path $envPath) {
    $lines = Get-Content $envPath | Where-Object { $_ -notmatch "^ABUTRON_QUANT_MODE=" }
    $lines += ""
    $lines += "# Step 23Q observational only"
    $lines += "ABUTRON_QUANT_MODE=SHADOW"
    Set-Content -Path $envPath -Value $lines
}
Log "STEP23Q_QUANT_MODE=SHADOW"

# ------------------------------------------------------------------
# 4. Run unit tests safely.
# Python unittest -v writes progress to stderr. Start-Process captures it
# without PowerShell converting normal stderr text into NativeCommandError.
# ------------------------------------------------------------------
$env:PYTHONPATH = $Root

Run-NativeChecked `
    -FilePath $Python `
    -ArgumentList @(
        "-m", "unittest", "discover",
        "-s", (Join-Path $PackageRoot "tests"),
        "-p", "test_step23q_quant.py",
        "-v"
    ) `
    -Name "STEP23Q_TESTS"

Log "STEP23Q_UNIT_TESTS=PASS"

# ------------------------------------------------------------------
# 5. Import/compile integration checks.
# ------------------------------------------------------------------
Run-NativeChecked `
    -FilePath $Python `
    -ArgumentList @(
        "-c",
        "from abutron.quant import QuantEngine; from abutron.service import TradingService; print('STEP23Q_IMPORTS=PASS')"
    ) `
    -Name "STEP23Q_IMPORTS"

Log "STEP23Q_IMPORTS=PASS"

# ------------------------------------------------------------------
# 6. QME must not contain execution/routing/risk-engine hooks.
# ------------------------------------------------------------------
$forbidden = Select-String `
    -Path "$quantDir\*.py" `
    -Pattern "order_send|gateway\.order|MT5Gateway|RiskEngine|make_order_plan|route_with_position_lock" `
    -CaseSensitive:$false `
    -ErrorAction SilentlyContinue

if ($forbidden) {
    $forbidden | ForEach-Object {
        Log "FORBIDDEN_REFERENCE=$($_.Path):$($_.LineNumber):$($_.Line)"
    }
    throw "STEP23Q_FORBIDDEN_EXECUTION_REFERENCE"
}
Log "STEP23Q_NO_EXECUTION_REFERENCE=PASS"

# ------------------------------------------------------------------
# 7. Confirm only OFF/SHADOW modes exist.
# ------------------------------------------------------------------
Run-NativeChecked `
    -FilePath $Python `
    -ArgumentList @(
        "-c",
        "from abutron.quant.engine import QuantMode; m={x.value for x in QuantMode}; assert m=={'OFF','SHADOW'},m; print('STEP23Q_MODE_CONTRACT=PASS')"
    ) `
    -Name "STEP23Q_MODE_CONTRACT"

Log "STEP23Q_MODE_CONTRACT=PASS"

# ------------------------------------------------------------------
# 8. Final source-level safety statement.
# ------------------------------------------------------------------
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP23Q_INSTALL=PASS"
Log "STEP23Q_RESUME_V1_0_1=PASS"

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 23Q INSTALL = PASS"
Write-Host " HOTFIX WRAPPER = v1.0.1"
Write-Host " MODE = SHADOW"
Write-Host " QME TESTS = PASS"
Write-Host " EXECUTION REFERENCES = NONE"
Write-Host " LIVE MONEY AUTHORIZED = FALSE"
Write-Host "===================================================="
Write-Host ""
Write-Host "NEXT:"
Write-Host "1. Restart the existing Abutron API/platform."
Write-Host "2. Confirm /health."
Write-Host "3. Run C:\Abutron\Step23Q-Package\scripts\certify_step23q.ps1"
Write-Host ""
Write-Host "Log: $Log"
