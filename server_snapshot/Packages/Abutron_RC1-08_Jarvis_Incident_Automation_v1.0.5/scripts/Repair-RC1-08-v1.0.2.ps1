param(
  [string]$JarvisRoot = "C:\Abutron\Jarvis",
  [string]$PackageRoot = "C:\Abutron\Packages\Abutron_RC1-08_Jarvis_Incident_Automation_v1.0.2"
)
$ErrorActionPreference = 'Stop'
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$rc = Join-Path $JarvisRoot 'rc1_08'
$cfgPath = Join-Path $rc 'config.json'
$envPath = Join-Path $JarvisRoot '.env'
$promCfg = Join-Path $JarvisRoot 'observability\prometheus\prometheus.yml'
$backup = Join-Path $JarvisRoot "backups\rc1_08_repair_$ts"
New-Item -ItemType Directory -Force $backup | Out-Null

function Wait-HttpOk([string]$Url,[int]$Seconds=45) {
  $deadline=(Get-Date).AddSeconds($Seconds)
  $last=$null
  do {
    try { return Invoke-RestMethod -Uri $Url -TimeoutSec 5 }
    catch { $last=$_.Exception.Message; Start-Sleep 2 }
  } while((Get-Date) -lt $deadline)
  throw "Health check failed: $Url ; last_error=$last"
}

function Stop-PrometheusClean {
  $task=Get-ScheduledTask -TaskName 'Abutron-Prometheus' -ErrorAction SilentlyContinue
  if($task){
    Stop-ScheduledTask -TaskName 'Abutron-Prometheus' -ErrorAction SilentlyContinue
    Start-Sleep 2
  }
  $deadline=(Get-Date).AddSeconds(15)
  do {
    $listener=Get-NetTCPConnection -LocalPort 9090 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $listener){ break }
    Stop-Process -Id $listener.OwningProcess -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
  } while((Get-Date) -lt $deadline)
  if(Get-NetTCPConnection -LocalPort 9090 -State Listen -ErrorAction SilentlyContinue){
    throw 'Prometheus port 9090 did not stop cleanly'
  }
  return $task
}

function Start-PrometheusKnownConfig([object]$task,[string]$config,[string]$promRoot){
  if($task){
    Start-ScheduledTask -TaskName 'Abutron-Prometheus'
  } else {
    $exe=Join-Path $promRoot 'prometheus.exe'
    if(!(Test-Path $exe)){ throw 'Prometheus executable missing' }
    $argString = "--config.file=`"$config`" --storage.tsdb.path=`"$promRoot\data`" --storage.tsdb.retention.time=15d --web.listen-address=127.0.0.1:9090"
    Start-Process -FilePath $exe -ArgumentList $argString -WorkingDirectory $promRoot -WindowStyle Hidden
  }
  Wait-HttpOk 'http://127.0.0.1:9090/-/ready' 45 | Out-Null

  $listener=Get-NetTCPConnection -LocalPort 9090 -State Listen -ErrorAction Stop | Select-Object -First 1
  $proc=Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
  Write-Host "Prometheus PID=$($listener.OwningProcess)"
  Write-Host "Prometheus command=$($proc.CommandLine)"
  if([string]$proc.CommandLine -notlike "*$config*"){
    throw "Prometheus is not running with expected config: $config"
  }
}

function Wait-PrometheusTargetUp([string]$Job,[int]$Seconds=90){
  $deadline=(Get-Date).AddSeconds($Seconds)
  $lastState='missing'
  do {
    try {
      $targets=Invoke-RestMethod 'http://127.0.0.1:9090/api/v1/targets' -TimeoutSec 10
      $t=@($targets.data.activeTargets | Where-Object {$_.labels.job -eq $Job})
      if($t.Count -eq 1){
        $lastState="health=$($t[0].health) lastError=$($t[0].lastError)"
        if($t[0].health -eq 'up'){ return $t[0] }
      } elseif($t.Count -gt 1) {
        throw "Multiple Prometheus targets found for job $Job"
      } else {
        $lastState='missing'
      }
    } catch {
      $lastState=$_.Exception.Message
    }
    Start-Sleep 3
  } while((Get-Date) -lt $deadline)
  throw "Prometheus target $Job failed to become UP within ${Seconds}s; last_state=$lastState"
}

Write-Host "=== RC1-08 v1.0.2 REPAIR / CERTIFICATION ==="

$core = Wait-HttpOk 'http://127.0.0.1:8088/health' 15
$mt5  = Wait-HttpOk 'http://127.0.0.1:8090/health' 15
Write-Host "PASS core 8088 and MT5 bridge 8090"

if(!(Test-Path $cfgPath)){ throw "Missing $cfgPath" }
if(!(Test-Path $envPath)){ throw "Missing $envPath" }
Copy-Item $cfgPath (Join-Path $backup 'config.json.before') -Force

# Installed layout is intentionally:
# C:\Abutron\Jarvis\rc1_08\config.json
# C:\Abutron\Jarvis\rc1_08\rc1_08\*.py
# because PYTHONPATH points at C:\Abutron\Jarvis\rc1_08.
$src = Join-Path $PackageRoot 'src\rc1_08'
$livePkg = Join-Path $rc 'rc1_08'
if(!(Test-Path $src)){ throw "Missing package source $src" }
New-Item -ItemType Directory -Force $livePkg | Out-Null
Copy-Item (Join-Path $src '*') $livePkg -Recurse -Force
Write-Host "Updated live RC1-08 Python package"

$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$k = @($cfg.checks | Where-Object { $_.name -eq 'kronos_health' })
if($k.Count -ne 1){ throw "Expected exactly one kronos_health check" }
$k[0].url = 'http://127.0.0.1:8088/health'
if(-not ($cfg.checks | Where-Object { $_.name -eq 'mt5_bridge_health' })){
  $new = [pscustomobject]@{type='url';name='mt5_bridge_health';url='http://127.0.0.1:8090/health';timeout=8;severity='CRITICAL'}
  $cfg.checks = @($cfg.checks) + $new
}
$cfg | ConvertTo-Json -Depth 30 | Set-Content $cfgPath -Encoding UTF8

Stop-ScheduledTask -TaskName 'Abutron-Jarvis-RC1-08' -ErrorAction SilentlyContinue
Start-Sleep 2
Start-ScheduledTask -TaskName 'Abutron-Jarvis-RC1-08'
$h = Wait-HttpOk 'http://127.0.0.1:8788/health' 30
if($h.mode -ne 'OBSERVE_ONLY'){ throw 'RC1-08 left OBSERVE_ONLY mode' }
$metricsCheck=Invoke-WebRequest 'http://127.0.0.1:8788/metrics' -UseBasicParsing -TimeoutSec 10
if($metricsCheck.StatusCode -ne 200 -or $metricsCheck.Content -notmatch 'jarvis_rc1_08_up 1'){
  throw 'RC1-08 /metrics endpoint is not scrape-ready'
}
Write-Host "PASS RC1-08 metrics endpoint scrape-ready"

$line=Get-Content $envPath | Where-Object {$_ -match '^JARVIS_API_TOKEN='} | Select-Object -First 1
if(!$line){ throw 'JARVIS_API_TOKEN missing' }
$token=$line.Substring(17).Trim()
$headers=@{Authorization="Bearer $token"}

1..2 | ForEach-Object {
  Invoke-RestMethod 'http://127.0.0.1:8788/collect' -Method Post -Headers $headers | Out-Null
  Start-Sleep 1
}
Write-Host "PASS RC1-08 restarted, startup reconciliation ran, and two healthy confirmations completed"

if(!(Test-Path $promCfg)){ throw "Missing $promCfg" }
Copy-Item $promCfg (Join-Path $backup 'prometheus.yml.before') -Force
$txt=Get-Content $promCfg -Raw
if($txt -notmatch 'job_name:\s*["'']?jarvis_rc1_08["'']?'){
@'

  - job_name: "jarvis_rc1_08"
    metrics_path: /metrics
    static_configs:
      - targets:
          - "127.0.0.1:8788"
'@ | Add-Content $promCfg -Encoding UTF8
  Write-Host "Added Prometheus jarvis_rc1_08 scrape job"
}else{
  Write-Host "Prometheus jarvis_rc1_08 scrape job already present"
}

$promRoot='C:\Abutron\Observability\Prometheus'
$promtool=Join-Path $promRoot 'promtool.exe'
if(Test-Path $promtool){
  & $promtool check config $promCfg
  if($LASTEXITCODE -ne 0){
    Copy-Item (Join-Path $backup 'prometheus.yml.before') $promCfg -Force
    throw 'Prometheus config invalid; rolled back'
  }
}
$task=Stop-PrometheusClean
Start-PrometheusKnownConfig $task $promCfg $promRoot
$t=Wait-PrometheusTargetUp 'jarvis_rc1_08' 90
Write-Host "PASS Prometheus jarvis_rc1_08 target UP; scrape=$($t.scrapeUrl)"

$dashSrc=Join-Path $PackageRoot 'observability\grafana\abutron-jarvis-rc1-08.json'
$dashDst='C:\Program Files\GrafanaLabs\grafana\conf\provisioning\dashboards\abutron'
if(Test-Path $dashSrc){
  Get-Content $dashSrc -Raw | ConvertFrom-Json | Out-Null
  New-Item -ItemType Directory -Force $dashDst | Out-Null
  Copy-Item $dashSrc $dashDst -Force
}
try{
  Restart-Service Grafana -ErrorAction Stop
  $g=Wait-HttpOk 'http://127.0.0.1:3000/api/health' 60
  Write-Host "PASS Grafana health: $($g.database) version=$($g.version)"
}catch{
  Write-Warning "Grafana did not become healthy: $($_.Exception.Message)"
  Get-Service Grafana -ErrorAction SilentlyContinue | Format-List Status,Name,StartType
  Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | Format-Table LocalAddress,LocalPort,OwningProcess
  $log='C:\Program Files\GrafanaLabs\grafana\data\log\grafana.log'
  if(Test-Path $log){ Get-Content $log -Tail 120 }
  throw
}

$inc=@(Invoke-RestMethod 'http://127.0.0.1:8788/incidents' -Headers $headers)
$apr=@(Invoke-RestMethod 'http://127.0.0.1:8788/approvals' -Headers $headers)

$badInc=@($inc | Where-Object { $_.check_name -in @('kronos_health','mt5_bridge_health','jarvis_api') -and $_.status -eq 'OPEN' })
if($badInc.Count -gt 0){ throw "Open critical RC1-08 monitored incidents remain: $($badInc.check_name -join ',')" }

$stale=@()
foreach($a in $apr){
  if($a.status -eq 'PENDING'){
    $related=@($inc | Where-Object {$_.id -eq $a.incident_id}) | Select-Object -First 1
    if($related -and $related.status -eq 'RECOVERED'){ $stale += $a }
  }
}
if($stale.Count -gt 0){ throw "Stale PENDING approvals remain for RECOVERED incidents" }

Write-Host "=== FINAL RC1-08 INCIDENTS ==="
$inc | Where-Object {$_.check_name -in @('kronos_health','mt5_bridge_health','jarvis_api')} |
  Select-Object id,check_name,severity,status,occurrence_count,recovered_at |
  Format-Table -AutoSize

Write-Host "=== FINAL RC1-08 APPROVALS ==="
$apr | Select-Object id,incident_id,action_type,status,decided_by | Format-Table -AutoSize

Write-Host "PASS no stale approvals for recovered incidents"
Write-Host "REPAIR_COMPLETE=True"
Write-Host "Backup=$backup"
