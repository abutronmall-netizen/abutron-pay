param([string]$Root='C:\Abutron\TradingPlatformV4',[string]$PythonLauncher='py')
$ErrorActionPreference='Stop'
$Source=Split-Path -Parent $PSScriptRoot
$Target=Join-Path $Root 'ctrader_cloud_gateway'
$Venv=Join-Path $Root '.venv_ctrader'
$Python=Join-Path $Venv 'Scripts\python.exe'
if (-not (Test-Path $Root)) { throw "TradingPlatformV4 root missing: $Root" }
Write-Host '===================================================='
Write-Host ' ABUTRON STEP 21A V1.0.1 - IC MARKETS cTRADER CLOUD'
Write-Host ' REPAIR-SAFE INSTALL - LIVE MONEY REMAINS DISABLED'
Write-Host '===================================================='

if (-not (Test-Path $Python)) { & $PythonLauncher -3.11 -m venv $Venv }
& $Python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw 'CTRADER_PIP_UPGRADE_FAIL' }
& $Python -m pip install -r (Join-Path $Source 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'CTRADER_DEPENDENCY_INSTALL_FAIL' }

New-Item -ItemType Directory -Force -Path $Target | Out-Null
# Copy the COMPLETE runtime/self-test tree. v1.0.0 omitted .env.example + core_integration.
foreach($name in @(
  'ctrader_gateway','core_integration','requirements.txt','.env.example','README.md',
  'MANIFEST.json','STEP21A_BUILD_REPORT.json','docs','tests','deployment','scripts'
)) {
  $src=Join-Path $Source $name
  if (-not (Test-Path $src)) { throw "SOURCE_ARTIFACT_MISSING:$name" }
  Copy-Item $src $Target -Recurse -Force
}

$envPath=Join-Path $Target '.env'
if (-not (Test-Path $envPath)) {
  Copy-Item (Join-Path $Source '.env.example') $envPath
  Write-Host 'CTRADER_ENV_CREATED=TRUE'
} else {
  Write-Host 'CTRADER_ENV_PRESERVED=TRUE'
}

# Generate only local service secrets. Never generate/guess Spotware credentials.
$txt=Get-Content $envPath -Raw
if ($txt -match 'CTRADER_INTERNAL_API_KEY=CHANGE_ME_GENERATED_BY_INSTALLER') {
  $key=& $Python -c "import secrets; print(secrets.token_urlsafe(48))"
  if ($LASTEXITCODE -ne 0) { throw 'INTERNAL_KEY_GENERATION_FAIL' }
  $txt=$txt -replace 'CTRADER_INTERNAL_API_KEY=CHANGE_ME_GENERATED_BY_INSTALLER',("CTRADER_INTERNAL_API_KEY="+$key)
}
if ($txt -match '(?m)^CTRADER_ENCRYPTION_KEY=\s*$') {
  $fernet=& $Python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
  if ($LASTEXITCODE -ne 0) { throw 'ENCRYPTION_KEY_GENERATION_FAIL' }
  $txt=$txt -replace '(?m)^CTRADER_ENCRYPTION_KEY=\s*$',("CTRADER_ENCRYPTION_KEY="+$fernet)
}
Set-Content $envPath $txt -Encoding UTF8

# Validate the INSTALLED target before touching the Abutron core adapter.
Push-Location $Target
try {
  foreach($requiredPath in @('.env.example','core_integration\volume.py','core_integration\ctrader_cloud.py','ctrader_gateway\app.py','tests\test_static.py')) {
    if (-not (Test-Path $requiredPath)) { throw "INSTALLED_ARTIFACT_MISSING:$requiredPath" }
  }
  & $Python -m compileall -q ctrader_gateway core_integration
  if ($LASTEXITCODE -ne 0) { throw 'CTRADER_COMPILE_FAIL' }
  & $Python -m pytest -q tests
  if ($LASTEXITCODE -ne 0) { throw 'CTRADER_TEST_FAIL' }
} finally { Pop-Location }

$envText=Get-Content $envPath -Raw
foreach($required in @(
  'CTRADER_ENABLE_LIVE_CONNECTION=false',
  'CTRADER_DEMO_EXECUTION_ENABLED=false',
  'CTRADER_LIVE_MONEY_AUTHORIZED=false',
  'CTRADER_KILL_SWITCH=true'
)) {
  if ($envText -notmatch [regex]::Escape($required)) { throw "SAFETY_DEFAULT_MISSING: $required" }
}

# Only after the isolated gateway passes self-tests, install the additive core adapter.
# This does NOT switch TradingService away from MT5.
$CoreGatewayDir=Join-Path $Root 'abutron\gateways'
New-Item -ItemType Directory -Force -Path $CoreGatewayDir | Out-Null
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
foreach($pair in @(
  @('core_integration\ctrader_cloud.py','ctrader_cloud.py'),
  @('core_integration\volume.py','ctrader_volume.py')
)) {
  $src=Join-Path $Target $pair[0]
  $dst=Join-Path $CoreGatewayDir $pair[1]
  if (Test-Path $dst) { Copy-Item $dst ($dst+".before_step21a_v101_"+$stamp+".bak") -Force }
  Copy-Item $src $dst -Force
}

Write-Host 'STEP21A_INSTALL=PASS'
Write-Host 'STEP21A_REPAIR_FROM_V1_0_0=PASS'
Write-Host 'CTRADER_TARGET_TREE=PASS'
Write-Host 'CTRADER_DEDICATED_VENV=PASS'
Write-Host 'KRONOS_VENV_UNCHANGED=TRUE'
Write-Host 'CTRADER_DEMO_EXECUTION_ENABLED=false'
Write-Host 'CTRADER_LIVE_MONEY_AUTHORIZED=false'
Write-Host 'CTRADER_KILL_SWITCH=true'
Write-Host 'BROKER_ORDER_SENT=False'
Write-Host 'NEXT=RUN_PREAPPROVAL_CHECK'
