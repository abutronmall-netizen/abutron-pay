param([string]$Root='C:\Abutron\TradingPlatformV4',[string]$PythonLauncher='py')
$ErrorActionPreference='Stop'
$Source=Split-Path -Parent $PSScriptRoot
$Target=Join-Path $Root 'ctrader_cloud_gateway'
$Venv=Join-Path $Root '.venv_ctrader'
$Python=Join-Path $Venv 'Scripts\python.exe'
if (-not (Test-Path $Root)) { throw "TradingPlatformV4 root missing: $Root" }
Write-Host '===================================================='
Write-Host ' ABUTRON STEP 21A - IC MARKETS cTRADER CLOUD GATEWAY'
Write-Host ' LIVE MONEY REMAINS DISABLED'
Write-Host '===================================================='
if (-not (Test-Path $Python)) { & $PythonLauncher -3.11 -m venv $Venv }
& $Python -m pip install --upgrade pip
& $Python -m pip install -r (Join-Path $Source 'requirements.txt')
New-Item -ItemType Directory -Force -Path $Target | Out-Null
foreach($name in @('ctrader_gateway','requirements.txt','docs','tests','deployment','scripts')) {
  $src=Join-Path $Source $name
  if (Test-Path $src) { Copy-Item $src $Target -Recurse -Force }
}
$envPath=Join-Path $Target '.env'
if (-not (Test-Path $envPath)) { Copy-Item (Join-Path $Source '.env.example') $envPath }
# Generate only local service secrets; never generate/guess Spotware credentials.
$txt=Get-Content $envPath -Raw
if ($txt -match 'CTRADER_INTERNAL_API_KEY=CHANGE_ME_GENERATED_BY_INSTALLER') {
  $key=& $Python -c "import secrets; print(secrets.token_urlsafe(48))"
  $txt=$txt -replace 'CTRADER_INTERNAL_API_KEY=CHANGE_ME_GENERATED_BY_INSTALLER',("CTRADER_INTERNAL_API_KEY="+$key)
}
if ($txt -match '(?m)^CTRADER_ENCRYPTION_KEY=\s*$') {
  $fernet=& $Python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
  $txt=$txt -replace '(?m)^CTRADER_ENCRYPTION_KEY=\s*$',("CTRADER_ENCRYPTION_KEY="+$fernet)
}
Set-Content $envPath $txt -Encoding UTF8
# Core adapter is additive; it does not switch TradingService away from MT5.
$CoreGatewayDir=Join-Path $Root 'abutron\gateways'; New-Item -ItemType Directory -Force -Path $CoreGatewayDir | Out-Null
Copy-Item (Join-Path $Source 'core_integration\ctrader_cloud.py') (Join-Path $CoreGatewayDir 'ctrader_cloud.py') -Force
Copy-Item (Join-Path $Source 'core_integration\volume.py') (Join-Path $CoreGatewayDir 'ctrader_volume.py') -Force
Push-Location $Target
try {
  & $Python -m compileall -q ctrader_gateway
  if ($LASTEXITCODE -ne 0) { throw 'CTRADER_COMPILE_FAIL' }
  & $Python -m pytest -q tests
  if ($LASTEXITCODE -ne 0) { throw 'CTRADER_TEST_FAIL' }
} finally { Pop-Location }
$envText=Get-Content $envPath -Raw
foreach($required in @('CTRADER_ENABLE_LIVE_CONNECTION=false','CTRADER_DEMO_EXECUTION_ENABLED=false','CTRADER_LIVE_MONEY_AUTHORIZED=false','CTRADER_KILL_SWITCH=true')) {
  if ($envText -notmatch [regex]::Escape($required)) { throw "SAFETY_DEFAULT_MISSING: $required" }
}
Write-Host 'STEP21A_INSTALL=PASS'
Write-Host 'CTRADER_DEDICATED_VENV=PASS'
Write-Host 'KRONOS_VENV_UNCHANGED=TRUE'
Write-Host 'CTRADER_DEMO_EXECUTION_ENABLED=false'
Write-Host 'CTRADER_LIVE_MONEY_AUTHORIZED=false'
Write-Host 'CTRADER_KILL_SWITCH=true'
Write-Host 'NEXT=RUN_PREAPPROVAL_CHECK'
