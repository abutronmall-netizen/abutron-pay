$ErrorActionPreference = "Stop"
$root = "C:\Abutron\TradingPlatformV4"
$envFile = "$root\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"
$helper = "$root\scripts\step20_soak_probe_v1_3.py"
$runner = "$root\scripts\Abutron-Step20-Soak-Endurance-Cert-v1.3.ps1"
$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"
$expectedHelperHash = "442C5F46A400E3AF7A3E5BE4D7534F72A97B2745D6955308E04CE5517A6CE9A2"
$expectedRunnerHash = "3ED6E024FC2FBBEE2CA3625052F40CBF551CA6D764BD783F37F74410A0C69F76"

# Normalize CWD so production BaseSettings resolves C:\Abutron\TradingPlatformV4\.env.
Set-Location $root
Write-Host "STEP20_WORKING_DIRECTORY_ROOT=PASS"

function Get-EnvValue {
    param([string]$Name)
    $escaped=[regex]::Escape($Name)
    $line=Get-Content $envFile | Where-Object { $_ -match "^\s*$escaped\s*=" } | Select-Object -First 1
    if (-not $line) { return $null }
    return (($line -split "=",2)[1]).Trim().Trim('"').Trim("'")
}
function Get-WorkerProcesses { return @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "(?i)(-m\s+abutron\.worker|abutron\\worker\.py)" }) }
function Get-ListenerPid { param([int]$Port); $x=Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if($x){[int]$x.OwningProcess}else{$null} }
function Invoke-Step20PythonHelper {
    param([string[]]$HelperArgs)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $pythonExe $helper @HelperArgs 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    foreach($line in $output) { Write-Host ([string]$line) }
    return [pscustomobject]@{ ExitCode=[int]$code; Output=@($output) }
}

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 20 V1.3 - INSTALL / VALIDATE / PREFLIGHT"
Write-Host " NO BROKER EXECUTION"
Write-Host "===================================================="

foreach($f in @($envFile,$pythonExe,$helper,$runner,$mt5Path)){ if(-not(Test-Path $f)){ throw "Missing Step20 file/prerequisite: $f" } }

$exec=[string](Get-EnvValue "ABUTRON_EXECUTION_ENABLED")
$live=[string](Get-EnvValue "MT5_LIVE_TRADING")
$mgmt=[string](Get-EnvValue "MT5_MANAGEMENT_ENABLED")
$demo=[string](Get-EnvValue "MT5_DEMO_ONLY")
if($exec.ToLowerInvariant()-ne"false" -or $live.ToLowerInvariant()-ne"false" -or $mgmt.ToLowerInvariant()-ne"false" -or $demo.ToLowerInvariant()-ne"true"){ throw "Production safety flags are not in the required Step20 state." }
if(@(Get-WorkerProcesses).Count-ne0){ throw "Worker must be OFF before Step20 preflight." }

$hh=(Get-FileHash $helper -Algorithm SHA256).Hash.ToUpperInvariant()
$rh=(Get-FileHash $runner -Algorithm SHA256).Hash.ToUpperInvariant()
if($hh-ne$expectedHelperHash){ throw "Step20 helper hash mismatch: $hh" }
if($rh-ne$expectedRunnerHash){ throw "Step20 runner hash mismatch: $rh" }
Write-Host "STEP20_V1_3_FILE_HASHES=PASS"

& $pythonExe -m py_compile $helper
if($LASTEXITCODE-ne0){ throw "Step20 helper Python syntax failed." }
$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors) | Out-Null
if($errors.Count-gt0){ $errors | ForEach-Object { Write-Host "PARSER_ERROR=$($_.Message)" }; throw "Step20 runner PowerShell syntax failed." }
Write-Host "STEP20_V1_3_SYNTAX=PASS"

# Validate the real strategy package topology before any diagnostic worker is allowed to start.
$strategyDir = "$root\abutron\strategies"
$requiredStrategyFiles = @(
    "$strategyDir\__init__.py",
    "$strategyDir\base.py",
    "$strategyDir\flipper.py",
    "$strategyDir\scalper.py",
    "$strategyDir\master.py"
)
if (-not (Test-Path $strategyDir -PathType Container)) { throw "Strategy package missing: $strategyDir" }
foreach($f in $requiredStrategyFiles){ if(-not(Test-Path $f -PathType Leaf)){ throw "Strategy source missing: $f" } }
& $pythonExe -c "from abutron.strategies import engine_for; assert callable(engine_for)"
if($LASTEXITCODE-ne0){ throw "Strategy package import/loadability failed." }
Write-Host "STEP20_V1_3_STRATEGY_PACKAGE=PASS"

foreach($port in @(8088,8090,8787,9090,3000,9182)){ if(-not(Get-ListenerPid $port)){ throw "Required Step20 listener missing on port $port." } }
Write-Host "STEP20_V1_3_LISTENER_BASELINE=PASS"

# Validate the authenticated read-only bridge contract now, rather than two minutes into the soak.
$bridgeToken = [string](Get-EnvValue "ABUTRON_MT5_TOKEN")
if([string]::IsNullOrWhiteSpace($bridgeToken)){ throw "ABUTRON_MT5_TOKEN unavailable." }
$bridgeHeaders = @{ Authorization = "Bearer $bridgeToken" }
$context = Invoke-RestMethod -Uri "http://127.0.0.1:8090/v1/context/XAUUSD" -Headers $bridgeHeaders -TimeoutSec 30
$bars = Invoke-RestMethod -Uri "http://127.0.0.1:8090/v1/bars/XAUUSD?timeframe=M1&count=64" -Headers $bridgeHeaders -TimeoutSec 30
if(-not $context -or -not $bars){ throw "Authenticated read-only bridge validation failed." }
Write-Host "STEP20_V1_3_AUTHENTICATED_BRIDGE_READS=PASS"

$result = Invoke-Step20PythonHelper -HelperArgs @("--mode","preflight","--mt5-path",$mt5Path)
Write-Host "STEP20_V1_3_HELPER_EXIT=$($result.ExitCode)"
if($result.ExitCode-ne0){
    Write-Host "STEP20_V1_3_PREFLIGHT=FAIL"
    Write-Host "DEMO_ORDER_SENT=False"
    Write-Host "DO_NOT_START_SOAK=True"
    throw "Step20 V1.3 helper preflight failed. Read STEP20_HELPER_ERROR above, correct the prerequisite, then rerun this same preflight."
}

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 20 V1.3 INSTALL / PREFLIGHT = PASS"
Write-Host "===================================================="
Write-Host "STEP20_V1_3_INSTALL_PRECHECK=PASS"
Write-Host "STEP20_STEP19_PREREQUISITE=PASS"
Write-Host "WORKER=OFF"
Write-Host "DEMO_ORDER_SENT=False"
Write-Host "LIVE_MONEY_AUTHORIZED=False"

Write-Host "NEXT_ACTION=RUN_15_MINUTE_DIAGNOSTIC"
Write-Host "===================================================="
