$ErrorActionPreference="Stop"
$Root=Split-Path $PSScriptRoot -Parent
Set-Location $Root
New-Item -ItemType Directory -Force -Path ".\vendor" | Out-Null
if (Test-Path ".\vendor\Kronos\.git") {
  git -C ".\vendor\Kronos" pull --ff-only
} else {
  git clone --depth 1 https://github.com/shiyu-coder/Kronos.git ".\vendor\Kronos"
}
if (!(Test-Path ".\vendor\Kronos\LICENSE")) { throw "Kronos LICENSE missing." }
Write-Host "Official Kronos source ready."
