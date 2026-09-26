$ErrorActionPreference='SilentlyContinue'
$Root=Split-Path $PSScriptRoot -Parent
$pidFile="$Root\data\platform_pids.txt"
if (Test-Path $pidFile) {
  Get-Content $pidFile | ForEach-Object { if ($_ -match '^\d+$') { Stop-Process -Id ([int]$_) -Force -ErrorAction SilentlyContinue } }
  Remove-Item $pidFile -Force
}
Write-Host "Abutron v4 processes stopped."
