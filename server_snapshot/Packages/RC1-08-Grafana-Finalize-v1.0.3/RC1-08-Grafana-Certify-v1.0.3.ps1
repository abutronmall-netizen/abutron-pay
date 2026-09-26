# Abutron RC1-08 Grafana / Final Pre-Reboot Certification v1.0.3
# Safe scope: OBSERVE_ONLY verification and observability repair only.
# Does not enable trading, restart Kronos/MT5, deploy trading code, or execute approved actions.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Pass([string]$Message) {
    Write-Host "PASS $Message" -ForegroundColor Green
}

function Write-Info([string]$Message) {
    Write-Host "INFO $Message" -ForegroundColor Cyan
}

function Wait-HttpJson {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [int]$TimeoutSeconds = 180,
        [int]$IntervalSeconds = 2
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        try {
            return Invoke-RestMethod -Uri $Url -TimeoutSec 5
        }
        catch {
            $last = $_.Exception.Message
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    throw "HTTP health timeout: $Url ; last_error=$last"
}

function Normalize-ApiCollection($obj) {
    if ($null -eq $obj) { return @() }
    if ($obj.PSObject.Properties.Name -contains "value") {
        return @($obj.value)
    }
    return @($obj)
}

Write-Host "=== ABUTRON RC1-08 v1.0.3 PRE-REBOOT CERTIFICATION ===" -ForegroundColor Yellow

# --------------------------------------------------------------------
# 1. Verify RC1-08 itself is healthy and still fail-safe.
# --------------------------------------------------------------------
$rc = Wait-HttpJson -Url "http://127.0.0.1:8788/health" -TimeoutSeconds 30
if ($rc.status -ne "ok") {
    throw "RC1-08 health status is not ok."
}
if ($rc.mode -ne "OBSERVE_ONLY") {
    throw "SAFETY FAIL: RC1-08 mode is '$($rc.mode)' instead of OBSERVE_ONLY."
}
Write-Pass "RC1-08 healthy and OBSERVE_ONLY"

# --------------------------------------------------------------------
# 2. Verify Prometheus is now scraping RC1-08 successfully.
# --------------------------------------------------------------------
$null = Wait-HttpJson -Url "http://127.0.0.1:9090/-/ready" -TimeoutSeconds 30
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:9090/api/v1/targets" -TimeoutSec 10
$target = @($targets.data.activeTargets) |
    Where-Object { $_.labels.job -eq "jarvis_rc1_08" } |
    Select-Object -First 1

if (-not $target) {
    throw "Prometheus target jarvis_rc1_08 is missing."
}
if ($target.health -ne "up") {
    throw "Prometheus target jarvis_rc1_08 is not UP. lastError=$($target.lastError)"
}
Write-Pass "Prometheus jarvis_rc1_08 target UP; scrape=$($target.scrapeUrl)"

# --------------------------------------------------------------------
# 3. Ensure the RC1-08 Grafana dashboard file is in the provisioned path.
#    IMPORTANT: the existing provider polls every 30 seconds, so a healthy
#    Grafana service is NOT restarted just to load a dashboard.
# --------------------------------------------------------------------
$grafanaRoot = "C:\Program Files\GrafanaLabs\grafana"
$provFile = Join-Path $grafanaRoot "conf\provisioning\dashboards\abutron-jarvis.yaml"
$dashDir = Join-Path $grafanaRoot "conf\provisioning\dashboards\abutron"
$dashDest = Join-Path $dashDir "abutron-jarvis-rc1-08.json"

if (-not (Test-Path $provFile)) {
    throw "Grafana Abutron dashboard provider missing: $provFile"
}

$provText = Get-Content $provFile -Raw
if ($provText -notmatch "updateIntervalSeconds:\s*30") {
    Write-Warning "Provider exists but does not show updateIntervalSeconds: 30. Continuing with health checks."
}
if ($provText -notmatch [regex]::Escape($dashDir)) {
    throw "Grafana provider does not point to expected Abutron dashboard folder: $dashDir"
}

New-Item -ItemType Directory -Path $dashDir -Force | Out-Null

$sourceCandidates = @(
    "C:\Abutron\Packages\Abutron_RC1-08_Jarvis_Incident_Automation_v1.0.2\observability\grafana\abutron-jarvis-rc1-08.json",
    "C:\Abutron\Packages\Abutron_RC1-08_Jarvis_Incident_Automation_v1.0.1\observability\grafana\abutron-jarvis-rc1-08.json",
    "C:\Abutron\Jarvis\observability\grafana\abutron-jarvis-rc1-08.json"
)

$dashSource = $sourceCandidates |
    Where-Object { Test-Path $_ } |
    Select-Object -First 1

if ($dashSource) {
    Copy-Item -Path $dashSource -Destination $dashDest -Force
    Write-Info "Dashboard copied from $dashSource"
}
elseif (-not (Test-Path $dashDest)) {
    throw "RC1-08 Grafana dashboard JSON not found in expected package/live locations."
}
else {
    Write-Info "Dashboard already present at $dashDest"
}

# --------------------------------------------------------------------
# 4. Grafana: first try current service as-is. Restart ONLY if it is
#    actually unhealthy. This avoids the startup race seen in v1.0.2.
# --------------------------------------------------------------------
$grafanaHealthy = $false
try {
    $g = Invoke-RestMethod -Uri "http://127.0.0.1:3000/api/health" -TimeoutSec 5
    if ($g.database -eq "ok") {
        $grafanaHealthy = $true
        Write-Pass "Grafana already healthy; no restart required. version=$($g.version)"
    }
}
catch {
    Write-Info "Grafana health not immediately available: $($_.Exception.Message)"
}

if (-not $grafanaHealthy) {
    $svc = Get-Service -Name "Grafana" -ErrorAction Stop
    if ($svc.Status -eq "Running") {
        Write-Info "Grafana service is running but HTTP health is unavailable; performing one controlled restart."
        Restart-Service -Name "Grafana" -Force
    }
    else {
        Write-Info "Grafana service is $($svc.Status); starting it."
        Start-Service -Name "Grafana"
    }

    # Wait for the TCP listener first.
    $tcpDeadline = (Get-Date).AddSeconds(180)
    $listener = $null
    while ((Get-Date) -lt $tcpDeadline) {
        $listener = Get-NetTCPConnection -LocalAddress "127.0.0.1" -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
        if ($listener) { break }
        Start-Sleep -Seconds 2
    }
    if (-not $listener) {
        throw "Grafana did not open 127.0.0.1:3000 within 180 seconds."
    }

    # The listener can exist just before the API is ready. Give it a short
    # grace period, then poll the API independently.
    Start-Sleep -Seconds 3
    $g = Wait-HttpJson -Url "http://127.0.0.1:3000/api/health" -TimeoutSeconds 180 -IntervalSeconds 2
    if ($g.database -ne "ok") {
        throw "Grafana API responded but database status is '$($g.database)'."
    }
    Write-Pass "Grafana healthy after controlled startup. version=$($g.version)"
}

# Provider polls every 30 seconds. Give it one full polling interval plus margin.
Start-Sleep -Seconds 35

if (-not (Test-Path $dashDest)) {
    throw "Grafana dashboard file disappeared from provisioned path."
}
Write-Pass "Grafana RC1-08 dashboard present in provisioned directory"

# --------------------------------------------------------------------
# 5. Verify no legacy stale PENDING approval remains attached to a
#    RECOVERED incident. If one exists, restart RC1-08 once to trigger
#    v1.0.2 startup reconciliation, then verify again.
# --------------------------------------------------------------------
$envFile = "C:\Abutron\Jarvis\.env"
$tokenLine = Get-Content $envFile |
    Where-Object { $_ -match '^JARVIS_API_TOKEN=' } |
    Select-Object -First 1

if (-not $tokenLine) {
    throw "JARVIS_API_TOKEN missing from $envFile"
}

$token = $tokenLine.Substring(17).Trim()
if ([string]::IsNullOrWhiteSpace($token)) {
    throw "JARVIS_API_TOKEN is empty."
}
$headers = @{ Authorization = "Bearer $token" }

function Get-StaleApprovalState {
    param([hashtable]$Headers)

    $incRaw = Invoke-RestMethod -Uri "http://127.0.0.1:8788/incidents" -Headers $Headers -TimeoutSec 10
    $aprRaw = Invoke-RestMethod -Uri "http://127.0.0.1:8788/approvals" -Headers $Headers -TimeoutSec 10

    $incidents = Normalize-ApiCollection $incRaw
    $approvals = Normalize-ApiCollection $aprRaw

    $recoveredIds = @{}
    foreach ($i in $incidents) {
        if ($i.status -eq "RECOVERED") {
            $recoveredIds[[string]$i.id] = $true
        }
    }

    $stale = @($approvals | Where-Object {
        $_.status -eq "PENDING" -and $recoveredIds.ContainsKey([string]$_.incident_id)
    })

    return [pscustomobject]@{
        Incidents = $incidents
        Approvals = $approvals
        Stale = $stale
    }
}

$state = Get-StaleApprovalState -Headers $headers

if ($state.Stale.Count -gt 0) {
    Write-Info "Found $($state.Stale.Count) stale PENDING approval(s) on RECOVERED incident(s); restarting RC1-08 once for startup reconciliation."
    Stop-ScheduledTask -TaskName "Abutron-Jarvis-RC1-08" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-ScheduledTask -TaskName "Abutron-Jarvis-RC1-08"
    $null = Wait-HttpJson -Url "http://127.0.0.1:8788/health" -TimeoutSeconds 60
    Start-Sleep -Seconds 5
    $state = Get-StaleApprovalState -Headers $headers
}

if ($state.Stale.Count -gt 0) {
    $ids = ($state.Stale | ForEach-Object { $_.id }) -join ", "
    throw "Stale recovered-incident approvals remain: $ids"
}
Write-Pass "No stale PENDING approvals attached to RECOVERED incidents"

# --------------------------------------------------------------------
# 6. Final open-incident gate for the three critical platform checks.
# --------------------------------------------------------------------
$blocking = @($state.Incidents | Where-Object {
    $_.status -eq "OPEN" -and $_.check_name -in @("kronos_health","mt5_bridge_health","jarvis_api")
})

if ($blocking.Count -gt 0) {
    $msg = ($blocking | ForEach-Object { "$($_.check_name):$($_.id)" }) -join ", "
    throw "Blocking platform incidents remain OPEN: $msg"
}
Write-Pass "No OPEN blocking incidents for Kronos, MT5 bridge, or Jarvis API"

# --------------------------------------------------------------------
# 7. Final evidence snapshot.
# --------------------------------------------------------------------
Write-Host ""
Write-Host "=== FINAL STATUS ===" -ForegroundColor Yellow

Get-ScheduledTask -TaskName "Abutron-Jarvis-RC1-08" |
    Select-Object TaskName,State |
    Format-Table -AutoSize

Invoke-RestMethod -Uri "http://127.0.0.1:8788/health" |
    Format-List

$prom = Invoke-RestMethod -Uri "http://127.0.0.1:9090/api/v1/targets"
@($prom.data.activeTargets) |
    Where-Object { $_.labels.job -eq "jarvis_rc1_08" } |
    Select-Object @{N="Job";E={$_.labels.job}},health,scrapeUrl,lastError |
    Format-Table -AutoSize

Invoke-RestMethod -Uri "http://127.0.0.1:3000/api/health" |
    Format-List

Write-Host ""
Write-Pass "RC1-08 PRE-REBOOT certification complete"
Write-Host "PRE_REBOOT_CERTIFIED=True" -ForegroundColor Green
Write-Host "NEXT_REQUIRED_GATE=Windows reboot persistence test" -ForegroundColor Yellow
