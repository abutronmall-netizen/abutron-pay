param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$PackageRoot = "C:\Abutron\Step23Q-Package"
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogDir = "C:\Abutron\Step23Q\logs"
$VerifyDir = "C:\Abutron\Step23Q\verify"
New-Item -ItemType Directory -Force -Path $LogDir,$VerifyDir | Out-Null
$Log = Join-Path $LogDir "step23q_resume_v1_0_2_$Stamp.log"

function Log([string]$Message) {
    $line = "$(Get-Date -Format s) $Message"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

function Run-PythonFile {
    param(
        [string]$PythonFile,
        [string]$Name
    )

    $outFile = Join-Path $LogDir "$($Name)_stdout_$Stamp.log"
    $errFile = Join-Path $LogDir "$($Name)_stderr_$Stamp.log"

    $p = Start-Process `
        -FilePath $Python `
        -ArgumentList @($PythonFile) `
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

Log "STEP23Q_RESUME_V1_0_2_START"

if (-not (Test-Path $Root)) { throw "ROOT_NOT_FOUND=$Root" }
if (-not (Test-Path $PackageRoot)) { throw "PACKAGE_ROOT_NOT_FOUND=$PackageRoot" }

$Python = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path $Python)) { throw "PYTHON_NOT_FOUND=$Python" }

# 1. Safety re-check.
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

# 2. Confirm installed QME integration.
$quantDir = Join-Path $Root "abutron\quant"
$servicePath = Join-Path $Root "abutron\service.py"
if (-not (Test-Path $quantDir)) { throw "STEP23Q_QUANT_PACKAGE_MISSING" }
if (-not (Test-Path $servicePath)) { throw "STEP23Q_SERVICE_MISSING" }

$service = Get-Content $servicePath -Raw
$markers = @(
    "from abutron.quant.engine import QuantEngine",
    "self.quant=QuantEngine.from_env()",
    '"QUANTITATIVE MATHEMATICS"',
    '"quant":quant.to_dict()',
    "thesis=create_thesis(symbol,kronos,features,mode,min_conf)",
    "risk=self.risk.evaluate(thesis,account,broker,bundle,tier=tier)",
    "plan=make_order_plan(",
    "if execute and settings.execution_enabled and result.plan:"
)

foreach ($marker in $markers) {
    if (-not $service.Contains($marker)) {
        throw "STEP23Q_SERVICE_MARKER_MISSING=$marker"
    }
}
Log "STEP23Q_SERVICE_PATCH_VERIFY=PASS"

# 3. Enforce SHADOW only.
if (Test-Path $envPath) {
    $lines = Get-Content $envPath | Where-Object { $_ -notmatch "^ABUTRON_QUANT_MODE=" }
    $lines += ""
    $lines += "# Step 23Q observational only"
    $lines += "ABUTRON_QUANT_MODE=SHADOW"
    Set-Content -Path $envPath -Value $lines
}
Log "STEP23Q_QUANT_MODE=SHADOW"

# 4. We already have 7/7 PASS from v1.0.1, but run them again safely.
$testOut = Join-Path $LogDir "tests_stdout_$Stamp.log"
$testErr = Join-Path $LogDir "tests_stderr_$Stamp.log"

$p = Start-Process `
    -FilePath $Python `
    -ArgumentList @(
        "-m","unittest","discover",
        "-s",(Join-Path $PackageRoot "tests"),
        "-p","test_step23q_quant.py",
        "-v"
    ) `
    -WorkingDirectory $Root `
    -RedirectStandardOutput $testOut `
    -RedirectStandardError $testErr `
    -Wait `
    -PassThru `
    -NoNewWindow

if (Test-Path $testOut) { Get-Content $testOut | ForEach-Object { Log "STEP23Q_TESTS OUT: $_" } }
if (Test-Path $testErr) { Get-Content $testErr | ForEach-Object { Log "STEP23Q_TESTS ERR: $_" } }
Log "STEP23Q_TESTS_EXIT_CODE=$($p.ExitCode)"
if ($p.ExitCode -ne 0) { throw "STEP23Q_UNIT_TESTS_FAIL" }
Log "STEP23Q_UNIT_TESTS=PASS"

# 5. Use verifier FILES, not python -c, to avoid PowerShell argument parsing.
$importVerifier = Join-Path $VerifyDir "verify_imports.py"
@'
from abutron.quant import QuantEngine
from abutron.service import TradingService
print("STEP23Q_IMPORTS=PASS")
'@ | Set-Content -Path $importVerifier -Encoding UTF8

$modeVerifier = Join-Path $VerifyDir "verify_mode_contract.py"
@'
from abutron.quant.engine import QuantMode
modes = {x.value for x in QuantMode}
assert modes == {"OFF", "SHADOW"}, modes
print("STEP23Q_MODE_CONTRACT=PASS")
'@ | Set-Content -Path $modeVerifier -Encoding UTF8

Run-PythonFile -PythonFile $importVerifier -Name "STEP23Q_IMPORTS"
Run-PythonFile -PythonFile $modeVerifier -Name "STEP23Q_MODE_CONTRACT"

# 6. Forbidden execution reference scan.
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

# 7. Syntax compile of installed quant package + service.
$compileVerifier = Join-Path $VerifyDir "verify_compile.py"
@'
from pathlib import Path
import py_compile

root = Path(r"C:\Abutron\TradingPlatformV4")
targets = list((root / "abutron" / "quant").glob("*.py")) + [root / "abutron" / "service.py"]
for target in targets:
    py_compile.compile(str(target), doraise=True)
print("STEP23Q_COMPILE=PASS")
'@ | Set-Content -Path $compileVerifier -Encoding UTF8

Run-PythonFile -PythonFile $compileVerifier -Name "STEP23Q_COMPILE"

# 8. Final result.
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP23Q_INSTALL=PASS"
Log "STEP23Q_RESUME_V1_0_2=PASS"

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 23Q INSTALL = PASS"
Write-Host " WRAPPER HOTFIX = v1.0.2"
Write-Host " MODE = SHADOW"
Write-Host " UNIT TESTS = PASS"
Write-Host " IMPORTS = PASS"
Write-Host " MODE CONTRACT = PASS"
Write-Host " COMPILE = PASS"
Write-Host " EXECUTION REFERENCES = NONE"
Write-Host " LIVE MONEY AUTHORIZED = FALSE"
Write-Host "===================================================="
Write-Host ""
Write-Host "NEXT:"
Write-Host "Restart the Abutron platform, verify /health, then run:"
Write-Host "C:\Abutron\Step23Q-Package\scripts\certify_step23q.ps1"
Write-Host ""
Write-Host "Log: $Log"
