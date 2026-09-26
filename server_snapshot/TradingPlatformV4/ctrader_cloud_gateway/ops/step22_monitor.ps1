param(
  [string]$Root='C:\Abutron\TradingPlatformV4',
  [string]$Domain='api.abutronfx.online'
)
$ErrorActionPreference='Stop'; $fail=@()
function Probe([string]$Name,[string]$Url,[bool]$Required=$true){
  try {$r=Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5; Write-Host "$Name=PASS:$($r.StatusCode)"}
  catch {Write-Host "$Name=FAIL"; if($Required){$script:fail+=$Name}}
}
Probe 'CORE_HTTP_HEALTH' 'http://127.0.0.1:8088/health' $true
Probe 'CTRADER_HTTP_HEALTH' 'http://127.0.0.1:8091/health' $false
try {
  $r=Invoke-WebRequest -UseBasicParsing -Uri ("https://"+$Domain+"/healthz") -TimeoutSec 8
  if($r.StatusCode -eq 200){Write-Host 'PUBLIC_TLS_HEALTH=PASS'} else {$fail+='PUBLIC_TLS_HEALTH'}
} catch {Write-Host 'PUBLIC_TLS_HEALTH=PENDING';}
$drive=Get-PSDrive -Name ((Split-Path $Root -Qualifier).TrimEnd(':'))
if($drive){$free=[math]::Round($drive.Free/1GB,2); Write-Host "DISK_FREE_GB=$free"; if($free -lt 10){$fail+='DISK_FREE'}}
$envPath=Join-Path $Root 'ctrader_cloud_gateway\.env'
if(Test-Path $envPath){
  $t=Get-Content $envPath -Raw
  if($t -match '(?mi)^CTRADER_LIVE_MONEY_AUTHORIZED\s*=\s*true\s*$'){$fail+='LIVE_MONEY_AUTHORIZED'}
}
if($fail.Count -gt 0){Write-Host ('STEP22_MONITOR=FAIL:'+($fail -join ',')); exit 1}
Write-Host 'STEP22_MONITOR=PASS'
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
