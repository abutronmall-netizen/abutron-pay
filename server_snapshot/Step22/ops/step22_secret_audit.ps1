param(
  [string]$Root='C:\Abutron\TradingPlatformV4'
)
$ErrorActionPreference='Stop'
function Read-EnvMap([string]$Path){
  $m=@{}; if(!(Test-Path $Path)){return $m}
  foreach($line in Get-Content $Path){
    if($line -match '^\s*#' -or $line -notmatch '='){continue}
    $p=$line -split '=',2; $m[$p[0].Trim()]=$p[1].Trim()
  }
  return $m
}
function Assert-NoWritableBroadAcl([string]$Path){
  if(!(Test-Path $Path)){return}
  $bad=@((Get-Acl $Path).Access | Where-Object {
    ($_.IdentityReference -match 'Everyone|BUILTIN\\Users|Authenticated Users') -and
    ($_.FileSystemRights.ToString() -match 'Write|Modify|FullControl') -and
    $_.AccessControlType -eq 'Allow'
  })
  if($bad.Count -gt 0){throw "INSECURE_SECRET_ACL:$Path"}
}
$coreEnv=Join-Path $Root '.env'; $ctEnv=Join-Path $Root 'ctrader_cloud_gateway\.env'
if(!(Test-Path $coreEnv)){throw 'CORE_ENV_MISSING'}
if(!(Test-Path $ctEnv)){throw 'CTRADER_ENV_MISSING'}
$coreRaw=Get-Content $coreEnv -Raw; $ctRaw=Get-Content $ctEnv -Raw
$c=Read-EnvMap $coreEnv; $g=Read-EnvMap $ctEnv
$placeholders=@('CHANGE_ME_LONG_RANDOM_TOKEN','CHANGE_ME_JWT_SECRET_AT_LEAST_32_CHARS','CHANGE_ME_DIFFERENT_LONG_RANDOM_TOKEN','CHANGE_ME_ADMIN_PASSWORD','CHANGE_ME_GENERATED_BY_INSTALLER')
foreach($v in $placeholders){if($coreRaw.Contains($v)){throw 'CORE_SECRET_PLACEHOLDER_PRESENT'}; if($ctRaw.Contains($v)){throw 'CTRADER_SECRET_PLACEHOLDER_PRESENT'}}
foreach($k in @('CTRADER_INTERNAL_API_KEY','CTRADER_ENCRYPTION_KEY')){
  if(!$g.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($g[$k])){throw "CTRADER_SECRET_NOT_CONFIGURED:$k"}
}
if($g['CTRADER_ENABLE_LIVE_CONNECTION'] -match '(?i)^true$'){throw 'LIVE_CONNECTION_MUST_REMAIN_FALSE'}
if($g['CTRADER_LIVE_MONEY_AUTHORIZED'] -match '(?i)^true$'){throw 'LIVE_MONEY_MUST_REMAIN_FALSE'}
Assert-NoWritableBroadAcl $coreEnv; Assert-NoWritableBroadAcl $ctEnv
Write-Host 'STEP22_SECRET_AUDIT=PASS'
Write-Host 'SECRET_VALUES_PRINTED=False'
Write-Host 'LIVE_MONEY_AUTHORIZED=False'
