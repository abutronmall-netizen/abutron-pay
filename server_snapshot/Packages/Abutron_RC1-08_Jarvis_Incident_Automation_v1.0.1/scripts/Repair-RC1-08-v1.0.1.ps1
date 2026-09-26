param(
  [string]$JarvisRoot = "C:\Abutron\Jarvis",
  [string]$PackageRoot = "C:\Abutron\Packages\Abutron_RC1-08_Jarvis_Incident_Automation_v1.0.1"
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
  do {
    try { $r=Invoke-RestMethod -Uri $Url -TimeoutSec 5; return $r } catch { Start-Sleep 2 }
  } while((Get-Date) -lt $deadline)
  throw "Health check failed: $Url"
}

Write-Host "=== RC1-08 v1.0.1 REPAIR ==="
# Preconditions: real endpoints must be healthy before changing monitoring.
$core = Wait-HttpOk 'http://127.0.0.1:8088/health' 15
$mt5  = Wait-HttpOk 'http://127.0.0.1:8090/health' 15
Write-Host "PASS core 8088 and MT5 bridge 8090"

if(!(Test-Path $cfgPath)){ throw "Missing $cfgPath" }
if(!(Test-Path $envPath)){ throw "Missing $envPath" }
Copy-Item $cfgPath (Join-Path $backup 'config.json.before') -Force

# Install corrected Python modules from this package if available.
$src = Join-Path $PackageRoot 'src\rc1_08'
if(Test-Path $src){
  Copy-Item $src $rc -Recurse -Force
  Write-Host "Updated RC1-08 Python modules from package"
}

# Correct monitoring targets and add MT5 bridge HTTP health.
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$k = @($cfg.checks | Where-Object { $_.name -eq 'kronos_health' })
if($k.Count -ne 1){ throw "Expected exactly one kronos_health check" }
$k[0].url = 'http://127.0.0.1:8088/health'
if(-not ($cfg.checks | Where-Object { $_.name -eq 'mt5_bridge_health' })){
  $new = [pscustomobject]@{type='url';name='mt5_bridge_health';url='http://127.0.0.1:8090/health';timeout=8;severity='CRITICAL'}
  $cfg.checks = @($cfg.checks) + $new
}
$cfg | ConvertTo-Json -Depth 30 | Set-Content $cfgPath -Encoding UTF8

# Restart incident service and force enough successful collections to recover the false 8001 incident.
Stop-ScheduledTask -TaskName 'Abutron-Jarvis-RC1-08' -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName 'Abutron-Jarvis-RC1-08'
$h = Wait-HttpOk 'http://127.0.0.1:8788/health' 30
if($h.mode -ne 'OBSERVE_ONLY'){ throw 'RC1-08 left OBSERVE_ONLY mode' }
$line=Get-Content $envPath | Where-Object {$_ -match '^JARVIS_API_TOKEN='} | Select-Object -First 1
if(!$line){ throw 'JARVIS_API_TOKEN missing' }
$token=$line.Substring(17).Trim(); $headers=@{Authorization="Bearer $token"}
1..2 | ForEach-Object { Invoke-RestMethod 'http://127.0.0.1:8788/collect' -Method Post -Headers $headers | Out-Null; Start-Sleep 1 }
Write-Host "PASS RC1-08 restarted and forced two healthy confirmations"

# Prometheus: append YAML to the FILE, never paste YAML directly into PowerShell.
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
}else{ Write-Host "Prometheus jarvis_rc1_08 scrape job already present" }

$promRoot='C:\Abutron\Observability\Prometheus'
$promtool=Join-Path $promRoot 'promtool.exe'
if(Test-Path $promtool){
  & $promtool check config $promCfg
  if($LASTEXITCODE -ne 0){ Copy-Item (Join-Path $backup 'prometheus.yml.before') $promCfg -Force; throw 'Prometheus config invalid; rolled back' }
}
$listener=Get-NetTCPConnection -LocalPort 9090 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if($listener){ Stop-Process -Id $listener.OwningProcess -Force; Start-Sleep 2 }
$pt=Get-ScheduledTask -TaskName 'Abutron-Prometheus' -ErrorAction SilentlyContinue
if($pt){ Start-ScheduledTask -TaskName 'Abutron-Prometheus' }
else{
  $exe=Join-Path $promRoot 'prometheus.exe'
  if(!(Test-Path $exe)){ throw 'Prometheus executable missing' }
  $args=@("--config.file=$promCfg","--storage.tsdb.path=$promRoot\data","--storage.tsdb.retention.time=15d","--web.listen-address=127.0.0.1:9090")
  Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $promRoot -WindowStyle Hidden
}
Wait-HttpOk 'http://127.0.0.1:9090/-/ready' 30 | Out-Null
Start-Sleep 16
$targets=Invoke-RestMethod 'http://127.0.0.1:9090/api/v1/targets'
$t=@($targets.data.activeTargets | Where-Object {$_.labels.job -eq 'jarvis_rc1_08'})
if($t.Count -ne 1 -or $t[0].health -ne 'up'){ throw 'Prometheus jarvis_rc1_08 target is not UP' }
Write-Host "PASS Prometheus jarvis_rc1_08 target UP"

# Grafana dashboard: validate JSON, copy, restart, wait properly, and print diagnostics on failure.
$dashSrc=Join-Path $PackageRoot 'observability\grafana\abutron-jarvis-rc1-08.json'
$dashDst='C:\Program Files\GrafanaLabs\grafana\conf\provisioning\dashboards\abutron'
if(Test-Path $dashSrc){ Get-Content $dashSrc -Raw | ConvertFrom-Json | Out-Null; New-Item -ItemType Directory -Force $dashDst | Out-Null; Copy-Item $dashSrc $dashDst -Force }
try{
  Restart-Service Grafana -ErrorAction Stop
  $g=Wait-HttpOk 'http://127.0.0.1:3000/api/health' 45
  Write-Host "PASS Grafana health: $($g.database) version=$($g.version)"
}catch{
  Write-Warning "Grafana did not become healthy: $($_.Exception.Message)"
  Get-Service Grafana -ErrorAction SilentlyContinue | Format-List Status,Name,StartType
  Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | Format-Table LocalAddress,LocalPort,OwningProcess
  $log='C:\Program Files\GrafanaLabs\grafana\data\log\grafana.log'
  if(Test-Path $log){ Get-Content $log -Tail 100 }
  throw
}

# Final evidence.
$inc=Invoke-RestMethod 'http://127.0.0.1:8788/incidents' -Headers $headers
$apr=Invoke-RestMethod 'http://127.0.0.1:8788/approvals' -Headers $headers
Write-Host "=== FINAL RC1-08 INCIDENTS ==="
$inc | Where-Object {$_.check_name -in @('kronos_health','mt5_bridge_health','jarvis_api')} | Select-Object id,check_name,severity,status,occurrence_count,recovered_at | Format-Table -AutoSize
Write-Host "=== FINAL RC1-08 APPROVALS ==="
$apr | Select-Object id,incident_id,action_type,status,decided_by | Format-Table -AutoSize
Write-Host "REPAIR_COMPLETE=True"
Write-Host "Backup=$backup"
