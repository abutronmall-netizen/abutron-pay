param([string]$Root="C:\Abutron\TradingPlatformV4",[string]$PackageRoot=(Split-Path $PSScriptRoot))
$ErrorActionPreference="Stop"
$Stamp=Get-Date -Format "yyyyMMdd-HHmmss"
$LogDir="C:\Abutron\Step23Q\logs";New-Item -ItemType Directory -Force -Path $LogDir|Out-Null
$Log=Join-Path $LogDir "step23q_install_$Stamp.log"
function Log($m){$l="$(Get-Date -Format s) $m";Write-Host $l;Add-Content $Log $l}
Log "STEP23Q_INSTALL_START"
$Python=Join-Path $Root ".venv\Scripts\python.exe";if(-not(Test-Path $Python)){throw "PYTHON_NOT_FOUND"}
$envPath=Join-Path $Root ".env";$envText=if(Test-Path $envPath){Get-Content $envPath -Raw}else{""}
foreach($d in @("ABUTRON_EXECUTION_ENABLED=true","MT5_LIVE_TRADING=true","MT5_MANAGEMENT_ENABLED=true","CTRADER_LIVE_EXECUTION_ENABLED=true","LIVE_MONEY_AUTHORIZED=true")){if($envText -match [regex]::Escape($d)){throw "STEP23Q_SAFETY_ABORT=$d"}}
Log "STEP23Q_LIVE_SAFETY=PASS"
$Pre=Get-ChildItem "C:\Abutron\Backups\PreStep23Q" -Directory|Sort-Object LastWriteTime -Descending|Select-Object -First 1
if(-not $Pre){throw "PRESTEP23Q_BACKUP_NOT_FOUND"}
foreach($rel in @("abutron\kronos_runtime.py","abutron\fusion.py","abutron\risk.py","abutron\capital.py","abutron\router.py")){
  $a=Join-Path $Root $rel;$b=Join-Path $Pre.FullName $rel
  if((Get-FileHash $a -Algorithm SHA256).Hash -ne (Get-FileHash $b -Algorithm SHA256).Hash){throw "PROTECTED_FILE_CHANGED=$rel"}
}
Log "STEP23Q_PROTECTED_BASELINE=PASS"
$src=Join-Path $PackageRoot "src\abutron\quant";$dst=Join-Path $Root "abutron\quant";New-Item -ItemType Directory -Force -Path $dst|Out-Null;Copy-Item "$src\*" $dst -Recurse -Force
Log "STEP23Q_QUANT_PACKAGE_COPY=PASS"
& $Python (Join-Path $PackageRoot "scripts\patch_service.py") $Root 2>&1|ForEach-Object{Log $_};if($LASTEXITCODE -ne 0){throw "STEP23Q_SERVICE_PATCH_FAIL"}
if(Test-Path $envPath){
  $lines=Get-Content $envPath|Where-Object{$_ -notmatch "^ABUTRON_QUANT_MODE="}
  $lines+="";$lines+="# Step 23Q observational only";$lines+="ABUTRON_QUANT_MODE=SHADOW";Set-Content $envPath $lines
}
$env:PYTHONPATH=$Root
& $Python -m unittest discover -s (Join-Path $PackageRoot "tests") -p "test_step23q_quant.py" -v 2>&1|ForEach-Object{Log $_}
if($LASTEXITCODE -ne 0){throw "STEP23Q_UNIT_TESTS_FAIL"}
& $Python -c "from abutron.quant import QuantEngine; from abutron.service import TradingService; print('STEP23Q_IMPORTS=PASS')" 2>&1|ForEach-Object{Log $_}
if($LASTEXITCODE -ne 0){throw "STEP23Q_IMPORTS_FAIL"}
$forbidden=Select-String -Path "$dst\*.py" -Pattern "order_send|gateway\.order|MT5Gateway|RiskEngine|make_order_plan|route_with_position_lock" -CaseSensitive:$false -ErrorAction SilentlyContinue
if($forbidden){$forbidden|ForEach-Object{Log "FORBIDDEN_REFERENCE=$($_.Line)"};throw "STEP23Q_FORBIDDEN_EXECUTION_REFERENCE"}
Log "STEP23Q_NO_EXECUTION_REFERENCE=PASS"
Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP23Q_INSTALL=PASS"
Write-Host "ABUTRON STEP 23Q INSTALL = PASS"
Write-Host "MODE=SHADOW"
Write-Host "Restart the Abutron API using your existing platform restart method, then run certify_step23q.ps1"
