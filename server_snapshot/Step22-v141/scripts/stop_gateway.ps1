param([string]$Root='C:\Abutron\TradingPlatformV4')
$Target=Join-Path $Root 'ctrader_cloud_gateway'; $PidFile=Join-Path $Target 'ctrader_gateway.pid'
if (Test-Path $PidFile) { $pid=[int](Get-Content $PidFile); Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue; Remove-Item $PidFile -Force -ErrorAction SilentlyContinue; Write-Host 'CTRADER_GATEWAY_STOPPED=TRUE' } else { Write-Host 'CTRADER_GATEWAY_STOPPED=ALREADY' }
