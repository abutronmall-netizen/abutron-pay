[CmdletBinding()]
param(
    [string]$Root = 'C:\Abutron\TradingPlatformV4',
    [switch]$SkipPrecheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SourceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptDir = Join-Path $Root 'scripts'
$DocsDir = Join-Path $Root 'docs\step21'
$RunnerName = 'Abutron-Step21-Controlled-Demo-Execution-Cert-v1.0.ps1'
$RunnerSource = Join-Path $SourceDir $RunnerName
$RunnerTarget = Join-Path $ScriptDir $RunnerName
$Manifest = Join-Path $SourceDir 'STEP21_MANIFEST.json'

Write-Host '===================================================='
Write-Host ' ABUTRON STEP 21 V1.0 - INSTALL / VERIFY / PRECHECK'
Write-Host ' DEMO ONLY - NO LIVE MONEY AUTHORIZATION'
Write-Host '===================================================='

foreach ($p in @($Root,$ScriptDir)) {
    if (-not (Test-Path $p)) { throw "Required path missing: $p" }
}
if (-not (Test-Path $RunnerSource)) { throw "Runner missing from bundle: $RunnerSource" }
if (-not (Test-Path $Manifest)) { throw "Manifest missing from bundle: $Manifest" }

New-Item -ItemType Directory -Path $DocsDir -Force | Out-Null
Copy-Item $RunnerSource $RunnerTarget -Force
Copy-Item (Join-Path $SourceDir 'README_STEP21.md') $DocsDir -Force
Copy-Item (Join-Path $SourceDir 'STEP21_INSTALLATION.md') $DocsDir -Force
Copy-Item $Manifest $DocsDir -Force

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($RunnerTarget,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host $_.Message }
    throw 'STEP21 PowerShell syntax validation failed.'
}
Write-Host 'STEP21_POWERSHELL_SYNTAX=PASS'

$bundleManifest = Get-Content $Manifest -Raw | ConvertFrom-Json
$expected = ($bundleManifest.files | Where-Object { $_.name -eq $RunnerName }).sha256
$actual = (Get-FileHash $RunnerTarget -Algorithm SHA256).Hash.ToUpperInvariant()
if (-not $expected -or $actual -ne $expected.ToUpperInvariant()) {
    throw "STEP21 runner hash mismatch. expected=$expected actual=$actual"
}
Write-Host 'STEP21_RUNNER_HASH=PASS'

foreach ($required in @(
    (Join-Path $ScriptDir 'Abutron-Step19-Equity-Router-Bot-Lifecycle-Cert.ps1'),
    (Join-Path $ScriptDir 'Abutron-Step19-MultiDemo-Cert-v1.4.ps1'),
    (Join-Path $ScriptDir 'step19_multi_demo_cert_v1_4.py')
)) {
    if (-not (Test-Path $required)) { throw "Step21 prerequisite missing: $required" }
}
Write-Host 'STEP21_STEP19_DEPENDENCIES=PASS'

$step20 = Get-ChildItem (Join-Path $Root 'logs') -Filter 'step20_summary_*.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $step20) { throw 'No Step20 summary found.' }
$s = Get-Content $step20.FullName -Raw | ConvertFrom-Json
if ($s.result -ne 'PASS' -or [double]$s.observed_minutes -lt 120.0 -or [bool]$s.live_money_authorized) {
    throw 'Step20 certification prerequisite is not valid for Step21.'
}
Write-Host 'STEP21_STEP20_PREREQUISITE=PASS'

if (-not $SkipPrecheck) {
    Write-Host ''
    Write-Host '--- RUNNING SAFE FLIPPER PRECHECK (NO BROKER ORDER) ---'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RunnerTarget -Mode PRECHECK -Tier FLIPPER
    if ($LASTEXITCODE -ne 0) { throw "Step21 install precheck failed; exit=$LASTEXITCODE" }
    Write-Host 'STEP21_INSTALL_PRECHECK=PASS'
}

Write-Host ''
Write-Host '===================================================='
Write-Host ' STEP 21 V1.0 INSTALLATION = PASS'
Write-Host '===================================================='
Write-Host "RUNNER=$RunnerTarget"
Write-Host "DOCS=$DocsDir"
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
Write-Host 'NEXT_ACTION=RUN_STEP21_PRECHECK_ALL'
Write-Host '===================================================='
