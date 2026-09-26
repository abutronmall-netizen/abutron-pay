$ErrorActionPreference="Stop"
$Root=Split-Path $PSScriptRoot -Parent
Set-Location $Root
& ".\.venv\Scripts\python.exe" -m pytest -q
Write-Host "Core:"
Invoke-RestMethod http://127.0.0.1:8088/health | ConvertTo-Json -Depth 5
Write-Host "MT5:"
Invoke-RestMethod http://127.0.0.1:8090/health | ConvertTo-Json -Depth 5
