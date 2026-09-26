param([string]$JarvisRoot = "C:\Abutron\Jarvis")

$ErrorActionPreference = "Stop"

$envFile = Join-Path $JarvisRoot ".env"
$token = $null

Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*JARVIS_API_TOKEN\s*=\s*(.+?)\s*$') {
        $token = $Matches[1].Trim().Trim('"').Trim("'")
    }
}

if ([string]::IsNullOrWhiteSpace($token) -or $token -eq "CHANGE_ME") {
    throw "JARVIS_API_TOKEN is missing or unsafe"
}

$headers = @{ "X-Jarvis-Token" = $token }

try {
    $snapshot = Invoke-RestMethod `
        -Uri "http://127.0.0.1:8787/v1/system/health" `
        -Headers $headers `
        -Method Get `
        -TimeoutSec 20

    $snapshot | ConvertTo-Json -Depth 12

    Write-Host ""
    Write-Host "STATUS=$($snapshot.status)"
    Write-Host "READY=$($snapshot.ready)"
    Write-Host "MODE=$($snapshot.mode)"
    Write-Host "COLLECTOR_MUTATES_HOST=$($snapshot.safety.collector_mutates_host)"

    if ($snapshot.mode -ne "OBSERVE_ONLY") {
        throw "Jarvis is not OBSERVE_ONLY"
    }
    if ($snapshot.safety.collector_mutates_host -ne $false) {
        throw "Collector safety invariant failed"
    }

    Write-Host "PHASE_2_1_RUNTIME_VERIFY=PASS"
}
finally {
    $token = $null
    $headers = $null
    $snapshot = $null
}
