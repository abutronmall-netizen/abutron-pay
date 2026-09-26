param(
  [Parameter(Mandatory=$true)][switch]$Apply,
  [string]$Root='C:\Abutron\TradingPlatformV4',
  [string]$CaddyDir='C:\caddy'
)
$ErrorActionPreference='Stop'
if(!$Apply){throw 'EXPLICIT_APPLY_REQUIRED'}
$src=Join-Path $Root 'ctrader_cloud_gateway\deployment\caddy\Caddyfile.step22'
if(!(Test-Path $src)){throw 'STEP22_CADDYFILE_MISSING'}
$cmd=Get-Command caddy.exe -ErrorAction SilentlyContinue
if($cmd){$CaddyExe=$cmd.Source}else{$candidate=Join-Path $CaddyDir 'caddy.exe'; if(Test-Path $candidate){$CaddyExe=$candidate}else{throw 'CADDY_BINARY_MISSING'}}
New-Item -ItemType Directory -Force -Path $CaddyDir|Out-Null
$dst=Join-Path $CaddyDir 'Caddyfile'; if(Test-Path $dst){Copy-Item $dst ($dst+'.before_step22_'+(Get-Date -Format 'yyyyMMdd_HHmmss')+'.bak') -Force}
Copy-Item $src $dst -Force
& $CaddyExe validate --config $dst --adapter caddyfile
if($LASTEXITCODE -ne 0){throw 'CADDY_VALIDATE_FAIL'}
$svc=Get-Service caddy -ErrorAction SilentlyContinue
if(!$svc){
  $bin='"'+$CaddyExe+'" run --config "'+$dst+'" --adapter caddyfile'
  & sc.exe create caddy start= auto binPath= $bin | Out-Null
  & sc.exe start caddy | Out-Null
}else{
  & $CaddyExe reload --config $dst --adapter caddyfile
  if($LASTEXITCODE -ne 0){throw 'CADDY_RELOAD_FAIL'}
}
Write-Host 'STEP22_CADDY_APPLY=PASS'
Write-Host 'PUBLIC_TLS_CONFIG_APPLIED=TRUE'
Write-Host 'INTERNAL_TRADING_ROUTES_PUBLIC=False'
