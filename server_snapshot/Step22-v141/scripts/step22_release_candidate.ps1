param(
 [Parameter(Mandatory=$true)][string]$UserId,
 [Parameter(Mandatory=$true)][Int64]$AccountId,
 [string]$Root='C:\Abutron\TradingPlatformV4',
 [string]$Domain='api.abutronfx.online'
)
$ErrorActionPreference='Stop'
$Target=Join-Path $Root 'ctrader_cloud_gateway'; $gateFail=@()
Write-Host '=== ABUTRON STEP22 RELEASE CANDIDATE GATE ==='
try {$r=Invoke-WebRequest -UseBasicParsing -Uri ("https://"+$Domain+"/healthz") -TimeoutSec 8; if($r.StatusCode -eq 200){Write-Host 'PUBLIC_TLS=PASS'}else{$gateFail+='PUBLIC_TLS'}} catch {$gateFail+='PUBLIC_TLS'; Write-Host 'PUBLIC_TLS=FAIL'}
$envText=Get-Content (Join-Path $Target '.env') -Raw
if($envText -match '(?mi)^CTRADER_CLIENT_ID\s*=\s*\S+' -and $envText -match '(?mi)^CTRADER_CLIENT_SECRET\s*=\s*\S+') {Write-Host 'SPOTWARE_CREDENTIALS=PRESENT'} else {$gateFail+='SPOTWARE_CREDENTIALS'; Write-Host 'SPOTWARE_CREDENTIALS=MISSING'}
if($envText -match '(?mi)^CTRADER_LIVE_MONEY_AUTHORIZED\s*=\s*true\s*$'){$gateFail+='LIVE_MONEY_MUST_STAY_FALSE_UNTIL_FINAL_SIGNOFF'}
$required=@('STEP21B_REAL_OAUTH_DISCOVERY','STEP21C_REAL_DEMO_LIFECYCLE','STEP21D_REAL_NETWORK_RECOVERY')
$db=Join-Path $Target 'data\ctrader_gateway.db'; $Py=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
if(!(Test-Path $db)){$gateFail+='CTRADER_DB'; Write-Host 'CTRADER_DB=MISSING'} else {Write-Host 'CTRADER_DB=PRESENT'}
$code=@'
import sqlite3,sys
p,user,account=sys.argv[1],sys.argv[2],int(sys.argv[3]); names=sys.argv[4:]
with sqlite3.connect(p) as c:
  tables={x[0] for x in c.execute("select name from sqlite_master where type='table'")}
  if 'certification_gate' not in tables:
    print('CERTIFICATION_GATE_TABLE=MISSING'); sys.exit(3)
  failed=False
  for n in names:
    r=c.execute("select status from certification_gate where user_id=? and ctid_account_id=? and gate=?",(str(user),account,n)).fetchone()
    status=r[0] if r else 'MISSING'; print(f'{n}={status}')
    if status!='PASS': failed=True
  if failed: sys.exit(4)
'@
$tmp=Join-Path $env:TEMP ('step22_gate_'+[guid]::NewGuid().ToString('N')+'.py'); Set-Content -Path $tmp -Value $code -Encoding UTF8
& $Py $tmp $db $UserId $AccountId @required
if($LASTEXITCODE -ne 0){$gateFail+='REAL_CTRADER_CERTS'}
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
if($gateFail.Count -gt 0){Write-Host ('STEP22_RELEASE_CANDIDATE=BLOCKED:'+($gateFail -join ',')); Write-Host 'LIVE_MONEY_AUTHORIZED=False'; exit 2}
Write-Host 'STEP22_RELEASE_CANDIDATE=PASS'
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
Write-Host 'NEXT=FINAL_GO_NO_GO'
