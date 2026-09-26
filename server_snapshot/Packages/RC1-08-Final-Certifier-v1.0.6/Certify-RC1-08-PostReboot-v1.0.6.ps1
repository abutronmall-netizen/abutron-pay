# Abutron RC1-08 Final Reboot Certification v1.0.6
# Certification-only patch. Does NOT modify the RC1-08 engine or enable execution.
# Requires RC1-08 v1.0.5 boot hardening to already be installed.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Wait-Json {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [int]$Seconds = 300
    )
    $deadline = (Get-Date).AddSeconds($Seconds)
    $last = $null
    do {
        try {
            return Invoke-RestMethod -Uri $Url -TimeoutSec 5
        }
        catch {
            $last = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)
    throw "Health timeout: $Url ; last_error=$last"
}

function Normalize($x) {
    if ($null -eq $x) { return @() }
    if ($x.PSObject.Properties.Name -contains "value") { return @($x.value) }
    return @($x)
}

Write-Host "=== RC1-08 v1.0.6 FINAL POST-REBOOT CERTIFICATION ===" -ForegroundColor Yellow

# -------------------------------------------------------------------
# 0. Reboot guard: prove Windows actually rebooted AFTER v1.0.5 deploy.
# -------------------------------------------------------------------
$enginePath = "C:\Abutron\Jarvis\rc1_08\rc1_08\engine.py"
if (-not (Test-Path $enginePath)) {
    throw "Missing deployed RC1-08 engine: $enginePath"
}

$deploymentUtc = (Get-Item $enginePath).LastWriteTimeUtc
$bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()

Write-Host "DeploymentUTC=$($deploymentUtc.ToString('o'))"
Write-Host "BootUTC=$($bootUtc.ToString('o'))"

if ($bootUtc -le $deploymentUtc) {
    throw "NO_REBOOT_AFTER_INSTALL: Windows boot time is not newer than the deployed RC1-08 v1.0.5 engine. Run Restart-Computer, reconnect, then run this certifier again."
}
Write-Host "PASS real Windows reboot occurred after v1.0.5 deployment" -ForegroundColor Green

# -------------------------------------------------------------------
# 1. Startup persistence.
# -------------------------------------------------------------------
$required = @("Abutron-Jarvis","Abutron-Jarvis-RC1-08","Abutron-Prometheus")
foreach ($n in $required) {
    $t = Get-ScheduledTask -TaskName $n -ErrorAction Stop
    if ($t.State -ne "Running") {
        throw "$n is not Running (state=$($t.State))"
    }
}
Write-Host "PASS required scheduled tasks Running" -ForegroundColor Green

# -------------------------------------------------------------------
# 2. Jarvis + Hermes.
# -------------------------------------------------------------------
$j = Wait-Json -Url "http://127.0.0.1:8787/health" -Seconds 180
if ($j.status -ne "ok" -or $j.mode -ne "OBSERVE_ONLY" -or $j.hermes.status -ne "ok") {
    throw "Jarvis/Hermes health gate failed"
}
Write-Host "PASS Jarvis + Hermes healthy and OBSERVE_ONLY" -ForegroundColor Green

# -------------------------------------------------------------------
# 3. RC1-08 startup grace and post-grace stability.
# -------------------------------------------------------------------
$rc = Wait-Json -Url "http://127.0.0.1:8788/health" -Seconds 180
if ($rc.status -ne "ok" -or $rc.mode -ne "OBSERVE_ONLY") {
    throw "RC1-08 health gate failed"
}

$deadline = (Get-Date).AddSeconds(240)
do {
    $rc = Invoke-RestMethod -Uri "http://127.0.0.1:8788/health" -TimeoutSec 5
    if (-not $rc.startup_grace_active) { break }
    Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)

if ($rc.startup_grace_active) {
    throw "RC1-08 startup grace did not expire within 240 seconds"
}

# Allow two normal collection intervals after grace.
Start-Sleep -Seconds 70
$rc = Invoke-RestMethod -Uri "http://127.0.0.1:8788/health" -TimeoutSec 5

Write-Host ("PASS RC1-08 stable after grace; cycles={0}; suppressed_failures={1}" -f `
    $rc.cycles, $rc.suppressed_failures_total) -ForegroundColor Green

# -------------------------------------------------------------------
# 4. Kronos + MT5 bridge.
# -------------------------------------------------------------------
$core = Wait-Json -Url "http://127.0.0.1:8088/health" -Seconds 60
$mt5  = Wait-Json -Url "http://127.0.0.1:8090/health" -Seconds 60

if ($core.status -ne "ok" -or -not $core.kronos_loaded) {
    throw "Kronos core gate failed"
}
if ($mt5.status -ne "ok" -or -not $mt5.mt5_connected) {
    throw "MT5 bridge gate failed"
}
if ($core.execution_enabled -eq $true) {
    throw "SAFETY FAIL: Kronos execution_enabled unexpectedly true"
}
Write-Host "PASS Kronos + MT5 healthy; execution remains disabled" -ForegroundColor Green

# -------------------------------------------------------------------
# 5. Prometheus + Grafana.
# -------------------------------------------------------------------
Invoke-RestMethod -Uri "http://127.0.0.1:9090/-/ready" -TimeoutSec 10 | Out-Null
$targets = Invoke-RestMethod -Uri "http://127.0.0.1:9090/api/v1/targets" -TimeoutSec 10
$p = @($targets.data.activeTargets | Where-Object { $_.labels.job -eq "jarvis_rc1_08" })

if ($p.Count -ne 1 -or $p[0].health -ne "up") {
    throw "Prometheus jarvis_rc1_08 target is not UP"
}

$g = Wait-Json -Url "http://127.0.0.1:3000/api/health" -Seconds 180
if ($g.database -ne "ok") {
    throw "Grafana database is not ok"
}
Write-Host "PASS Prometheus + Grafana healthy" -ForegroundColor Green

# -------------------------------------------------------------------
# 6. Incident/approval gate.
#    ONLY incidents opened on this NEW boot count as boot-hardening evidence.
# -------------------------------------------------------------------
$line = Get-Content "C:\Abutron\Jarvis\.env" |
    Where-Object { $_ -match "^JARVIS_API_TOKEN=" } |
    Select-Object -First 1

if (-not $line) {
    throw "JARVIS_API_TOKEN missing"
}

$headers = @{ Authorization = "Bearer " + $line.Substring(17).Trim() }

$inc = Normalize (Invoke-RestMethod -Uri "http://127.0.0.1:8788/incidents" -Headers $headers -TimeoutSec 10)
$apr = Normalize (Invoke-RestMethod -Uri "http://127.0.0.1:8788/approvals" -Headers $headers -TimeoutSec 10)

$criticalNames = @("jarvis_api","kronos_health","mt5_bridge_health")

$bootIncidents = @($inc | Where-Object {
    $_.check_name -in $criticalNames -and
    ([datetimeoffset]$_.opened_at).UtcDateTime -ge $bootUtc
})

$open = @($inc | Where-Object {
    $_.check_name -in $criticalNames -and $_.status -eq "OPEN"
})

if ($open.Count -gt 0) {
    $open | Select-Object id,check_name,status,summary,opened_at | Format-Table -AutoSize
    throw "OPEN blocking incidents remain after reboot"
}

if ($bootIncidents.Count -gt 0) {
    $bootIncidents |
        Select-Object id,check_name,status,summary,opened_at,recovered_at |
        Format-Table -AutoSize
    throw "BOOT_HARDENING_FAILED: this real post-v1.0.5 reboot created critical platform incidents"
}

$recovered = @{}
foreach ($i in $inc) {
    if ($i.status -eq "RECOVERED") {
        $recovered[[string]$i.id] = $true
    }
}

$stale = @($apr | Where-Object {
    $_.status -eq "PENDING" -and
    $recovered.ContainsKey([string]$_.incident_id)
})

if ($stale.Count -gt 0) {
    $stale | Select-Object id,incident_id,status,action_type,created_at | Format-Table -AutoSize
    throw "Stale pending approvals exist for recovered incidents"
}

Write-Host "PASS no critical incidents created on this reboot" -ForegroundColor Green
Write-Host "PASS no stale PENDING approvals on recovered incidents" -ForegroundColor Green

# -------------------------------------------------------------------
# 7. Final certification snapshot.
# -------------------------------------------------------------------
Write-Host ""
Write-Host "=== FINAL RC1-08 STATUS ===" -ForegroundColor Yellow
Write-Host "BootUTC=$($bootUtc.ToString('o'))"
Write-Host "DeploymentUTC=$($deploymentUtc.ToString('o'))"
Write-Host "RC1-08 cycles=$($rc.cycles)"
Write-Host "Suppressed transient failures=$($rc.suppressed_failures_total)"
Write-Host "Prometheus target=$($p[0].health)"
Write-Host "Grafana database=$($g.database)"
Write-Host ""

Write-Host "RC1_08_CERTIFIED=True" -ForegroundColor Green
Write-Host "RC1-08 — Jarvis Incident Automation CERTIFIED" -ForegroundColor Green
Write-Host "NEXT=RC1-09 Telegram + WhatsApp/Meta Alerts" -ForegroundColor Yellow
