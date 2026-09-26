param([string]$Root="C:\Abutron\TradingPlatformV4")
$ErrorActionPreference="Stop"
Write-Host "=== STEP 26A PRE-INSTALL AUDIT ==="
Invoke-RestMethod "http://127.0.0.1:8088/health"|ConvertTo-Json -Depth 10
Write-Host "`nCurrent product/API routes:"

Push-Location
try {
    Set-Location $Root
    & ".\.venv\Scripts\python.exe" -c "from abutron.api import app; [print(','.join(sorted(getattr(r,'methods',[]) or [])),r.path) for r in app.routes]"
    Write-Host "`nStep23Q latest certification:"
    Get-ChildItem ".\certification\step23q\STEP23Q_CERTIFICATION_*.json" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 |
        ForEach-Object { Get-Content $_.FullName }
}
finally {
    Pop-Location
}
