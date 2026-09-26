param(
  [string]$Root='C:\Abutron\TradingPlatformV4',
  [string]$Domain='api.abutronfx.online'
)
$ErrorActionPreference='Stop'
Write-Host '=== STEP22 SERVICE / NETWORK INVENTORY ==='
foreach($p in @(8088,8090,8091,80,443)){
  $rows=@(Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue)
  if($rows.Count -eq 0){Write-Host "PORT_${p}_LISTENER=NONE"; continue}
  $addrs=($rows | Select-Object -ExpandProperty LocalAddress -Unique) -join ','
  Write-Host "PORT_${p}_LISTENER=$addrs"
  $publicBinds=@($rows | Where-Object {$_.LocalAddress -in @('0.0.0.0','::')})
  if($p -in @(8088,8090,8091) -and $publicBinds.Count -gt 0){throw "INTERNAL_PORT_PUBLIC_BIND:$p"}
}
try {$dns=(Resolve-DnsName $Domain -Type A -ErrorAction Stop | Where-Object {$_.IPAddress} | Select-Object -ExpandProperty IPAddress) -join ','; Write-Host "PUBLIC_DNS_A=$dns"} catch {Write-Host 'PUBLIC_DNS_A=UNRESOLVED'}
$caddy=Get-Command caddy.exe -ErrorAction SilentlyContinue
if($caddy){Write-Host "CADDY_BIN=$($caddy.Source)"} else {Write-Host 'CADDY_BIN=MISSING'}
$svc=Get-Service caddy -ErrorAction SilentlyContinue
if($svc){Write-Host "CADDY_SERVICE=$($svc.Status)"} else {Write-Host 'CADDY_SERVICE=MISSING'}
Write-Host 'INTERNAL_PORT_EXPOSURE_CHECK=PASS'
