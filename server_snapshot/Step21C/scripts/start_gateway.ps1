param([string]$Root='C:\Abutron\TradingPlatformV4')
$ErrorActionPreference='Stop'
$Target=Join-Path $Root 'ctrader_cloud_gateway'; $Python=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
$PidFile=Join-Path $Target 'ctrader_gateway.pid'; $Out=Join-Path $Target 'logs\gateway.stdout.log'; $Err=Join-Path $Target 'logs\gateway.stderr.log'
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
if (Test-Path $PidFile) { $old=[int](Get-Content $PidFile); if (Get-Process -Id $old -ErrorAction SilentlyContinue) { Write-Host "CTRADER_GATEWAY_ALREADY_RUNNING_PID=$old"; exit 0 } }
$proc=Start-Process -FilePath $Python -ArgumentList @('-m','uvicorn','ctrader_gateway.app:app','--host','127.0.0.1','--port','8091') -WorkingDirectory $Target -RedirectStandardOutput $Out -RedirectStandardError $Err -PassThru
Set-Content $PidFile $proc.Id
Start-Sleep -Seconds 2
Write-Host "CTRADER_GATEWAY_PID=$($proc.Id)"
