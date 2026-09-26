param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$TaskName = "Abutron-ADVL-dxFeed"
)
$ErrorActionPreference = "Stop"
$Python = Join-Path $Root ".venv\Scripts\python.exe"
$Collector = Join-Path $Root "tools\advl_dxfeed\advl_dxfeed_collector.py"
$EnvFile = Join-Path $Root "secrets\dxfeed_advl.env"

if (-not (Test-Path $Python)) { throw "Python not found: $Python" }
if (-not (Test-Path $Collector)) { throw "Collector not found: $Collector" }
if (-not (Test-Path $EnvFile)) { throw "Config not found: $EnvFile" }

$ConfigText = Get-Content $EnvFile -Raw
if ($ConfigText -notmatch '(?m)^DXFEED_MODE=production\s*$') {
    throw "DXFEED_MODE must be production before registering the live collector task."
}
if (($ConfigText -notmatch '(?m)^DXFEED_TOKEN=\S+') -and
    (($ConfigText -notmatch '(?m)^DXFEED_USERNAME=\S+') -or ($ConfigText -notmatch '(?m)^DXFEED_PASSWORD=\S+'))) {
    throw "Production credentials are missing in dxfeed_advl.env."
}

$Args = '"' + $Collector + '" --root "' + $Root + '" --env "' + $EnvFile + '"'
$Action = New-ScheduledTaskAction -Execute $Python -Argument $Args -WorkingDirectory (Split-Path $Collector -Parent)
$Trigger = New-ScheduledTaskTrigger -AtStartup
$Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -User "SYSTEM" -RunLevel Highest -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3

$Task = Get-ScheduledTask -TaskName $TaskName
$Info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "TASK=$TaskName"
Write-Host "STATE=$($Task.State)"
Write-Host "LAST_RESULT=$($Info.LastTaskResult)"
Write-Host "Collector registered to start at boot and restart after failures." -ForegroundColor Green
