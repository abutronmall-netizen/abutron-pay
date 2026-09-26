param(
    [switch]$RunDiagnostic15Min
)

$ErrorActionPreference = "Stop"
$root = "C:\Abutron\TradingPlatformV4"
$envFile = "$root\.env"
$pythonExe = "$root\.venv\Scripts\python.exe"
$helper = "$root\scripts\step20_soak_probe_v1.py"
$runner = "$root\scripts\Abutron-Step20-Soak-Endurance-Cert-v1.ps1"
$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"
$expectedHelperHash = "F4612987C17CCBE4208748D0828A78C116C694E2D402D24ACF0235B62F5ED470"
$expectedRunnerHash = "751B06A21A2E34BA534CADB3EBD1C1E1119A05C0C4A8B98AEDB435A0ED05D353"

function Get-EnvValue {
    param([string]$Name)
    $escaped=[regex]::Escape($Name)
    $line=Get-Content $envFile | Where-Object { $_ -match "^\s*$escaped\s*=" } | Select-Object -First 1
    if (-not $line) { return $null }
    return (($line -split "=",2)[1]).Trim().Trim('"').Trim("'")
}
function Get-WorkerProcesses { return @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "(?i)(-m\s+abutron\.worker|abutron\\worker\.py)" }) }
function Get-ListenerPid { param([int]$Port); $x=Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if($x){[int]$x.OwningProcess}else{$null} }

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 20 - INSTALL / VALIDATE / PREFLIGHT"
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
Write-Host "STEP20_FILE_HASHES=PASS"

& $pythonExe -m py_compile $helper
if($LASTEXITCODE-ne0){ throw "Step20 helper Python syntax failed." }
$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile($runner,[ref]$tokens,[ref]$errors) | Out-Null
if($errors.Count-gt0){ $errors | ForEach-Object { Write-Host "PARSER_ERROR=$($_.Message)" }; throw "Step20 runner PowerShell syntax failed." }
Write-Host "STEP20_SYNTAX=PASS"

foreach($port in @(8088,8090,8787,9090,3000,9182)){ if(-not(Get-ListenerPid $port)){ throw "Required Step20 listener missing on port $port." } }
Write-Host "STEP20_LISTENER_BASELINE=PASS"

$out=@(& $pythonExe $helper --mode preflight --mt5-path $mt5Path 2>&1)
$exit=$LASTEXITCODE
foreach($line in $out){ Write-Host ([string]$line) }
if($exit-ne0){ throw "Step20 helper preflight failed. Switch MT5 to the canonical production-pinned DEMO account and retry." }

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP 20 INSTALL / PREFLIGHT = PASS"
Write-Host "===================================================="
Write-Host "STEP20_INSTALL_PRECHECK=PASS"
Write-Host "STEP20_STEP19_PREREQUISITE=PASS"
Write-Host "WORKER=OFF"
Write-Host "DEMO_ORDER_SENT=False"
Write-Host "LIVE_MONEY_AUTHORIZED=False"

if($RunDiagnostic15Min){
    Write-Host "STEP20_DIAGNOSTIC_STARTING=True"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -DurationMinutes 15 -SampleSeconds 15 -DiagnosticOnly
    exit $LASTEXITCODE
}

Write-Host "NEXT_ACTION=RUN_120_MINUTE_STEP20_CERTIFICATION"
Write-Host "===================================================="
