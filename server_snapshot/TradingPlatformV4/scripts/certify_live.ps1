$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
Set-Location $Root
$envFile=Get-Content '.env'
function EnvValue($name){ (($envFile | Where-Object {$_ -match "^$name="}) -split '=',2)[1] }
$token=EnvValue 'ABUTRON_API_TOKEN'
$headers=@{Authorization="Bearer $token"}
Write-Host '1/5 Core health'
Invoke-RestMethod 'http://127.0.0.1:8088/health' | ConvertTo-Json -Depth 8
Write-Host '2/5 MT5 health'
Invoke-RestMethod 'http://127.0.0.1:8090/health' | ConvertTo-Json -Depth 8
Write-Host '3/5 Live XAUUSD pipeline — DRY RUN'
Invoke-RestMethod -Method Post -Headers $headers 'http://127.0.0.1:8088/v1/live/XAUUSD?execute=false' | ConvertTo-Json -Depth 14
Write-Host '4/5 Positions'
Invoke-RestMethod -Headers $headers 'http://127.0.0.1:8088/v1/positions' | ConvertTo-Json -Depth 8
Write-Host '5/5 Automated tests'
& '.\.venv\Scripts\python.exe' -m pytest -q
Write-Host 'Dry-run certification complete. Do NOT enable live execution until docs\100_PERCENT_ACCEPTANCE_GATES.md is signed off.' -ForegroundColor Yellow
