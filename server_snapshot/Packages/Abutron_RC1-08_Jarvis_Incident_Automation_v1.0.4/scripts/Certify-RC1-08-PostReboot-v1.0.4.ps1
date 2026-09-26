$ErrorActionPreference='Stop'
function Wait-Json([string]$Url,[int]$Seconds=300){
  $deadline=(Get-Date).AddSeconds($Seconds); $last=$null
  do { try { return Invoke-RestMethod -Uri $Url -TimeoutSec 5 } catch { $last=$_.Exception.Message; Start-Sleep 2 } } while((Get-Date)-lt $deadline)
  throw "Health timeout: $Url ; last_error=$last"
}
function Normalize($x){ if($null -eq $x){return @()} ; if($x.PSObject.Properties.Name -contains 'value'){return @($x.value)} ; return @($x) }

Write-Host '=== RC1-08 v1.0.4 POST-REBOOT CERTIFICATION ===' -ForegroundColor Yellow
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
Write-Host "BootUTC=$($boot.ToString('o'))"

$required=@('Abutron-Jarvis','Abutron-Jarvis-RC1-08','Abutron-Prometheus')
foreach($n in $required){
  $t=Get-ScheduledTask -TaskName $n -ErrorAction Stop
  if($t.State -ne 'Running'){throw "$n is not Running (state=$($t.State))"}
}
Write-Host 'PASS required scheduled tasks Running' -ForegroundColor Green

$j=Wait-Json 'http://127.0.0.1:8787/health' 180
if($j.status -ne 'ok' -or $j.mode -ne 'OBSERVE_ONLY' -or $j.hermes.status -ne 'ok'){throw 'Jarvis/Hermes health gate failed'}
Write-Host 'PASS Jarvis + Hermes healthy' -ForegroundColor Green

$rc=Wait-Json 'http://127.0.0.1:8788/health' 180
if($rc.status -ne 'ok' -or $rc.mode -ne 'OBSERVE_ONLY'){throw 'RC1-08 health gate failed'}

# Wait for grace to finish, then allow two normal collection intervals.
$deadline=(Get-Date).AddSeconds(240)
do {
  $rc=Invoke-RestMethod 'http://127.0.0.1:8788/health' -TimeoutSec 5
  if(-not $rc.startup_grace_active){break}
  Start-Sleep 3
} while((Get-Date)-lt $deadline)
if($rc.startup_grace_active){throw 'RC1-08 startup grace did not expire'}
Start-Sleep 70
$rc=Invoke-RestMethod 'http://127.0.0.1:8788/health' -TimeoutSec 5
Write-Host "PASS RC1-08 stable after grace; cycles=$($rc.cycles); suppressed_failures=$($rc.suppressed_failures_total)" -ForegroundColor Green

$core=Wait-Json 'http://127.0.0.1:8088/health' 60
$mt5=Wait-Json 'http://127.0.0.1:8090/health' 60
if($core.status -ne 'ok' -or -not $core.kronos_loaded){throw 'Kronos core gate failed'}
if($mt5.status -ne 'ok' -or -not $mt5.mt5_connected){throw 'MT5 bridge gate failed'}
Write-Host 'PASS Kronos + MT5 healthy' -ForegroundColor Green

Invoke-RestMethod 'http://127.0.0.1:9090/-/ready' -TimeoutSec 10 | Out-Null
$targets=Invoke-RestMethod 'http://127.0.0.1:9090/api/v1/targets' -TimeoutSec 10
$p=@($targets.data.activeTargets | Where-Object {$_.labels.job -eq 'jarvis_rc1_08'})
if($p.Count -ne 1 -or $p[0].health -ne 'up'){throw 'Prometheus jarvis_rc1_08 target is not UP'}
$g=Wait-Json 'http://127.0.0.1:3000/api/health' 180
if($g.database -ne 'ok'){throw 'Grafana database is not ok'}
Write-Host 'PASS Prometheus + Grafana healthy' -ForegroundColor Green

$line=Get-Content 'C:\Abutron\Jarvis\.env' | Where-Object {$_ -match '^JARVIS_API_TOKEN='} | Select-Object -First 1
if(!$line){throw 'JARVIS_API_TOKEN missing'}
$headers=@{Authorization='Bearer '+$line.Substring(17).Trim()}
$inc=Normalize (Invoke-RestMethod 'http://127.0.0.1:8788/incidents' -Headers $headers -TimeoutSec 10)
$apr=Normalize (Invoke-RestMethod 'http://127.0.0.1:8788/approvals' -Headers $headers -TimeoutSec 10)

$criticalNames=@('jarvis_api','kronos_health','mt5_bridge_health')
$newBootInc=@($inc | Where-Object {
  $_.check_name -in $criticalNames -and ([datetimeoffset]$_.opened_at).UtcDateTime -ge $boot
})
$open=@($inc | Where-Object {$_.check_name -in $criticalNames -and $_.status -eq 'OPEN'})
if($open.Count -gt 0){throw "OPEN blocking incidents remain: $($open.check_name -join ', ')"}
if($newBootInc.Count -gt 0){
  $newBootInc | Select-Object id,check_name,status,summary,opened_at,recovered_at | Format-Table -AutoSize
  throw 'Post-v1.0.4 reboot created critical boot incidents; hardening gate FAILED'
}

$recovered=@{}; foreach($i in $inc){if($i.status -eq 'RECOVERED'){$recovered[[string]$i.id]=$true}}
$stale=@($apr | Where-Object {$_.status -eq 'PENDING' -and $recovered.ContainsKey([string]$_.incident_id)})
if($stale.Count -gt 0){throw 'Stale pending approvals exist for recovered incidents'}
Write-Host 'PASS no critical boot incidents and no stale approvals' -ForegroundColor Green

Write-Host ''
Write-Host 'RC1_08_CERTIFIED=True' -ForegroundColor Green
Write-Host 'RC1-08 — Jarvis Incident Automation CERTIFIED' -ForegroundColor Green
Write-Host 'NEXT=RC1-09 Telegram + WhatsApp/Meta Alerts' -ForegroundColor Yellow
