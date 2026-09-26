param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$PackageRoot = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference="Stop"

Write-Host "STEP26A_REPAIR_START"

$Python=Join-Path $Root ".venv\Scripts\python.exe"
if(-not(Test-Path $Python)){throw "PYTHON_NOT_FOUND=$Python"}

foreach($required in @(
    (Join-Path $PackageRoot "src\abutron\step26a_models.py"),
    (Join-Path $PackageRoot "src\abutron\step26a_api.py"),
    (Join-Path $PackageRoot "admin\step26a.html"),
    (Join-Path $PackageRoot "mobile\AbutronMobile\App.tsx")
)){
    if(-not(Test-Path $required)){throw "PACKAGE_FILE_MISSING=$required"}
}

# Re-run the normal installer. v1.0.1 is safe to resume after a partial v1.0.0 install.
& (Join-Path $PSScriptRoot "install_step26a.ps1") -Root $Root -PackageRoot $PackageRoot
if($LASTEXITCODE -ne 0){throw "STEP26A_REPAIR_INSTALL_FAILED"}

Write-Host "STEP26A_REPAIR=PASS"
