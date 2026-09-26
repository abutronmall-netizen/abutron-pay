param(
    [string]$Project = "C:\Abutron\TradingPlatformV4\mobile\AbutronMobile",
    [string]$PublicApi = "https://api.abutronfx.online"
)

$ErrorActionPreference = "Stop"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$StepRoot = "C:\Abutron\Step26B"
$LogDir = Join-Path $StepRoot "logs"
$BackupDir = Join-Path $StepRoot ("backup\" + $Stamp)
New-Item -ItemType Directory -Force -Path $LogDir,$BackupDir | Out-Null
$Log = Join-Path $LogDir "step26b_prepare_$Stamp.log"

function Log([string]$Message) {
    $line = "$(Get-Date -Format s) $Message"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

function Run([string]$Exe,[string[]]$Args,[string]$Name) {
    Log ("RUN={0} {1}" -f $Exe,($Args -join " "))
    & $Exe @Args
    if($LASTEXITCODE -ne 0) {
        throw ("{0}_FAIL exit={1}" -f $Name,$LASTEXITCODE)
    }
    Log ("{0}=PASS" -f $Name)
}

Log "STEP26B_PREPARE_V1_0_1_START"

if(-not(Test-Path $Project)){ throw "STEP26B_PROJECT_NOT_FOUND=$Project" }
Set-Location $Project

foreach($f in @("package.json","app.json","eas.json","tsconfig.json","App.tsx","src\api.ts")) {
    if(-not(Test-Path (Join-Path $Project $f))) {
        throw ("STEP26B_REQUIRED_FILE_MISSING={0}" -f $f)
    }
}
Log "STEP26B_REQUIRED_FILES=PASS"

# Backup package/build config before npm/expo can normalize versions.
foreach($f in @("package.json","package-lock.json","app.json","eas.json","tsconfig.json")) {
    $src = Join-Path $Project $f
    if(Test-Path $src) {
        Copy-Item $src (Join-Path $BackupDir ([IO.Path]::GetFileName($f))) -Force
    }
}
Log ("STEP26B_BACKUP=PASS:{0}" -f $BackupDir)

# Node/npm prerequisites.
$nodeVersion = (& node --version).Trim().TrimStart("v")
$npmVersion = (& npm --version).Trim()
if(-not $nodeVersion){ throw "STEP26B_NODE_NOT_FOUND" }
$parts = $nodeVersion.Split(".")
$major = [int]$parts[0]
$minor = [int]$parts[1]
if(($major -lt 22) -or (($major -eq 22) -and ($minor -lt 13))) {
    throw ("STEP26B_NODE_TOO_OLD={0}; Expo SDK 57 requires Node >=22.13.x" -f $nodeVersion)
}
Log ("STEP26B_NODE=PASS:{0}" -f $nodeVersion)
Log ("STEP26B_NPM=PASS:{0}" -f $npmVersion)

# Validate declared project versions before installing.
$pkg = Get-Content (Join-Path $Project "package.json") -Raw | ConvertFrom-Json
if(-not $pkg.dependencies.expo){ throw "STEP26B_PACKAGE_EXPO_MISSING" }
if(-not $pkg.dependencies."react-native"){ throw "STEP26B_PACKAGE_REACT_NATIVE_MISSING" }
if(-not $pkg.devDependencies.typescript){ throw "STEP26B_PACKAGE_TYPESCRIPT_MISSING" }
Log ("STEP26B_DECLARED_EXPO={0}" -f $pkg.dependencies.expo)
Log ("STEP26B_DECLARED_REACT_NATIVE={0}" -f $pkg.dependencies."react-native")
Log ("STEP26B_DECLARED_TYPESCRIPT={0}" -f $pkg.devDependencies.typescript)
Log "STEP26B_PACKAGE_CONTRACT=PASS"

# First dependency materialization. npm ci is intentionally NOT used until lockfile exists.
if(-not(Test-Path (Join-Path $Project "package-lock.json"))) {
    Log "STEP26B_LOCKFILE=MISSING; using npm install once to create deterministic lockfile"
    Run "npm.cmd" @("install","--no-audit","--no-fund") "STEP26B_NPM_INSTALL"
} else {
    Run "npm.cmd" @("ci","--no-audit","--no-fund") "STEP26B_NPM_CI"
}

if(-not(Test-Path (Join-Path $Project "package-lock.json"))) {
    throw "STEP26B_LOCKFILE_CREATE_FAIL"
}
Log "STEP26B_LOCKFILE=PASS"

# Ask Expo to align SDK-related dependency versions.
Run "npx.cmd" @("expo","install","--fix") "STEP26B_EXPO_DEPENDENCY_FIX"

# Lockfile/package consistency after Expo normalization.
Run "npm.cmd" @("ci","--dry-run","--no-audit","--no-fund") "STEP26B_LOCK_CONSISTENCY"

# Project diagnostics and TypeScript.
Run "npx.cmd" @("expo-doctor") "STEP26B_EXPO_DOCTOR"
Run "npm.cmd" @("run","typecheck") "STEP26B_TYPESCRIPT"

# EAS CLI: use npx so PATH/global install is not a blocker.
Run "npx.cmd" @("eas-cli@latest","--version") "STEP26B_EAS_CLI"
Log "STEP26B_EAS_USE_NPX=True"

# Static mobile safety scan.
$mobileFiles = @()
$mobileFiles += Get-Item (Join-Path $Project "App.tsx")
$mobileFiles += Get-ChildItem (Join-Path $Project "src") -File -Recurse -ErrorAction SilentlyContinue

$patterns = @(
    "order_send",
    "/v1/order",
    "/v1/live",
    "/v1/manage",
    "/v1/close",
    "gateway\.order",
    "MT5Gateway",
    "CTRADER_CLIENT_SECRET",
    "CLIENT_SECRET\s*=",
    "ABUTRON_API_TOKEN",
    "OPENAI_API_KEY",
    "sk-[A-Za-z0-9_-]{12,}"
)
$hits = @()
foreach($pattern in $patterns) {
    $hits += Select-String -Path $mobileFiles.FullName -Pattern $pattern -CaseSensitive:$false -ErrorAction SilentlyContinue
}
if($hits) {
    $hits | ForEach-Object {
        Log ("STEP26B_FORBIDDEN_MOBILE_REF={0}:{1}:{2}" -f $_.Path,$_.LineNumber,$_.Line.Trim())
    }
    throw "STEP26B_MOBILE_SAFETY_SCAN_FAIL"
}
Log "STEP26B_NO_ORDER_ENTRY_OR_CLIENT_SECRETS=PASS"

# Verify production URL exists in config/source.
$configText = (Get-Content (Join-Path $Project "app.json") -Raw) + "`n" +
              (Get-Content (Join-Path $Project "src\api.ts") -Raw)
if($configText -notmatch [regex]::Escape($PublicApi)) {
    throw ("STEP26B_PUBLIC_API_NOT_CONFIGURED={0}" -f $PublicApi)
}
Log ("STEP26B_PUBLIC_API_CONFIG=PASS:{0}" -f $PublicApi)

# Public HTTPS gate. We want the phone to be able to leave localhost.
try {
    $publicHealth = Invoke-RestMethod ($PublicApi.TrimEnd("/") + "/health") -TimeoutSec 20
    if($publicHealth.status -ne "ok") {
        throw "health status not ok"
    }
    if($publicHealth.execution_enabled -ne $false) {
        throw "execution_enabled must remain false"
    }
    Log "STEP26B_PUBLIC_HTTPS_HEALTH=PASS"
}
catch {
    Log ("STEP26B_PUBLIC_HTTPS_HEALTH=FAIL:{0}" -f $_.Exception.Message)
    throw "STEP26B_PUBLIC_HTTPS_GATE_FAIL"
}

Log "LIVE_MONEY_AUTHORIZED=False"
Log "STEP26B_PREPARE=PASS"

Write-Host ""
Write-Host "===================================================="
Write-Host " ABUTRON STEP 26B PREPARE = PASS"
Write-Host " Dependencies + lockfile = PASS"
Write-Host " Expo Doctor = PASS"
Write-Host " TypeScript = PASS"
Write-Host " EAS CLI via npx = PASS"
Write-Host " Mobile execution/secret scan = PASS"
Write-Host " Public HTTPS API = PASS"
Write-Host " Live money authorized = FALSE"
Write-Host "===================================================="
Write-Host ""
Write-Host "NEXT — interactive Expo/EAS account setup:"
Write-Host "  npx eas-cli@latest login"
Write-Host "  npx eas-cli@latest whoami"
Write-Host "  npx eas-cli@latest init"
Write-Host ""
Write-Host "Then set the public API variable:"
Write-Host ("  npx eas-cli@latest env:set production --name EXPO_PUBLIC_API_URL --value {0} --visibility plaintext" -f $PublicApi)
Write-Host ""
Write-Host "Do NOT run production builds until preview builds and device tests pass."
Write-Host ("Log: {0}" -f $Log)
