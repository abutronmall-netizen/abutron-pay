param([string]$Root="C:\Abutron\TradingPlatformV4")
$ErrorActionPreference="Stop"
Write-Host "=== STEP 27 PRE-INSTALL AUDIT ==="
Invoke-RestMethod "http://127.0.0.1:8088/health"|ConvertTo-Json -Depth 10
Write-Host "`nLatest Step26A certification:"
Get-ChildItem "$Root\certification\step26a\STEP26A_CERTIFICATION_*.json" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    ForEach-Object {Get-Content $_.FullName}
Write-Host "`nStep27 files already present:"
Get-ChildItem "$Root\abutron\step27_*.py","$Root\admin\step27.html" -ErrorAction SilentlyContinue |
    Select-Object FullName,Length,LastWriteTime
