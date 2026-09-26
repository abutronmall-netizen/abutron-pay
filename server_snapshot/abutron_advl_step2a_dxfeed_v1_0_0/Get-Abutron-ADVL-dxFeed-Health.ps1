param(
    [string]$Root = "C:\Abutron\TradingPlatformV4",
    [string]$TaskName = "Abutron-ADVL-dxFeed"
)
$ErrorActionPreference = "Stop"
$Feed = Join-Path $Root "runtime\advl_breadth.json"
$Status = Join-Path $Root "runtime\advl_dxfeed_status.json"

Write-Host "=== ABUTRON ADVL dxFeed HEALTH ===" -ForegroundColor Cyan
try {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $Info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "TASK_STATE=$($Task.State)"
    Write-Host "TASK_LAST_RESULT=$($Info.LastTaskResult)"
} catch {
    Write-Host "TASK_STATE=NOT_REGISTERED"
}

if (Test-Path $Status) {
    Write-Host "--- STATUS ---"
    Get-Content $Status -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10
} else {
    Write-Host "STATUS_FILE=MISSING"
}

if (Test-Path $Feed) {
    Write-Host "--- FEED ---"
    Get-Content $Feed -Raw | ConvertFrom-Json | ConvertTo-Json -Depth 10
} else {
    Write-Host "FEED_FILE=MISSING"
}
