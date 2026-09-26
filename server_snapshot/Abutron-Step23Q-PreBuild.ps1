param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$StepRoot = "C:\Abutron\Step23Q"
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$BackupRoot = "C:\Abutron\Backups\PreStep23Q\$Stamp"
$LogRoot = Join-Path $StepRoot "logs"
$LogFile = Join-Path $LogRoot "step23q_prebuild_$Stamp.log"

function Log($msg) {
    $line = "$(Get-Date -Format s) $msg"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

New-Item -ItemType Directory -Force -Path $StepRoot,$LogRoot,$BackupRoot | Out-Null
Log "STEP23Q_PREBUILD_START"

if (-not (Test-Path $Root)) {
    throw "TradingPlatformV4 root not found: $Root"
}
Log "ROOT_PRESENT=PASS"

Set-Location $Root

# Safety: verify known live/execution switches are not enabled.
$envFile = Join-Path $Root ".env"
if (Test-Path $envFile) {
    $envText = Get-Content $envFile -Raw
    $danger = @(
        "ABUTRON_EXECUTION_ENABLED=true",
        "MT5_LIVE_TRADING=true",
        "MT5_MANAGEMENT_ENABLED=true",
        "CTRADER_LIVE_EXECUTION_ENABLED=true",
        "LIVE_MONEY_AUTHORIZED=true"
    )
    foreach ($item in $danger) {
        if ($envText -match [regex]::Escape($item)) {
            throw "STEP23Q SAFETY ABORT: live/execution switch enabled: $item"
        }
    }
    Copy-Item $envFile (Join-Path $BackupRoot ".env.backup") -Force
    Log "EXECUTION_SWITCH_AUDIT=PASS"
} else {
    Log "ENV_FILE=NOT_FOUND"
}

# Snapshot critical source before any Step23Q build.
$critical = @(
    "abutron\service.py",
    "abutron\config.py",
    "abutron\models.py",
    "abutron\kronos_runtime.py",
    "abutron\fusion.py",
    "abutron\risk.py",
    "abutron\capital.py",
    "abutron\router.py"
)

$manifest = @()
foreach ($rel in $critical) {
    $src = Join-Path $Root $rel
    if (Test-Path $src) {
        $dest = Join-Path $BackupRoot $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
        Copy-Item $src $dest -Force
        $hash = (Get-FileHash $src -Algorithm SHA256).Hash
        $manifest += [pscustomobject]@{
            Path = $rel
            SHA256 = $hash
        }
        Log "SNAPSHOT_PASS=$rel"
    } else {
        Log "SNAPSHOT_MISSING=$rel"
    }
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $BackupRoot "SOURCE_HASHES.json")
Log "SOURCE_HASH_MANIFEST=PASS"

# Verify Python environment.
$python = Join-Path $Root ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    throw "Python venv not found: $python"
}
& $python --version 2>&1 | ForEach-Object { Log "PYTHON=$_"}
& $python -m pip check 2>&1 | ForEach-Object { Log "PIP_CHECK=$_"}
if ($LASTEXITCODE -ne 0) {
    throw "STEP23Q Python dependency check failed"
}
Log "PYTHON_ENV=PASS"

# Verify current core modules import before modification.
& $python -c "import abutron.service, abutron.kronos_runtime, abutron.fusion, abutron.risk, abutron.capital; print('CORE_IMPORTS=PASS')" 2>&1 |
    ForEach-Object { Log $_ }
if ($LASTEXITCODE -ne 0) {
    throw "STEP23Q baseline imports failed"
}

# Create isolated Step23Q workspace only. No production source edits here.
$dirs = @(
    "src",
    "tests",
    "certification",
    "docs",
    "artifacts"
)
foreach ($d in $dirs) {
    New-Item -ItemType Directory -Force -Path (Join-Path $StepRoot $d) | Out-Null
}
Log "STEP23Q_WORKSPACE=PASS"

# Record current service path for integration planning.
$service = Join-Path $Root "abutron\service.py"
if (Test-Path $service) {
    $matches = Select-String -Path $service -Pattern "KRONOS|FUSION|THESIS|RISK|CAPITAL|EQUITY ROUTER"
    $matches | Select-Object LineNumber,Line |
        Format-Table -AutoSize |
        Out-String |
        Set-Content (Join-Path $StepRoot "artifacts\CURRENT_PIPELINE_MAP.txt")
    Log "CURRENT_PIPELINE_MAP=PASS"
}

# Do not modify production source and do not start workers.
Log "PRODUCTION_SOURCE_MODIFIED=False"
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP23Q_PREBUILD=PASS"
Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 23Q PRE-BUILD = PASS"
Write-Host " Backup: $BackupRoot"
Write-Host " Log:    $LogFile"
Write-Host " No production trading logic was changed."
Write-Host "===================================================="
