[CmdletBinding()]
param([string]$GatewayRoot = "C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway")
$ErrorActionPreference = "Stop"
Write-Host ""
Write-Host "============================================================"
Write-Host " ABUTRON STEP 23 - SECURE cTRADER CREDENTIAL CONFIGURATION"
Write-Host " APPROVED APP ONLY - LIVE MONEY REMAINS DISABLED"
Write-Host "============================================================"
if (-not (Test-Path $GatewayRoot)) { throw "GATEWAY_ROOT_NOT_FOUND=$GatewayRoot" }
$EnvFile = Join-Path $GatewayRoot ".env"
$BackupDir = Join-Path $GatewayRoot "backups"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
if (Test-Path $EnvFile) {
  $stamp=Get-Date -Format "yyyyMMdd-HHmmss"
  Copy-Item $EnvFile (Join-Path $BackupDir ".env.pre-step23-$stamp") -Force
} else { New-Item -ItemType File -Path $EnvFile -Force | Out-Null }
$ClientId = Read-Host "CTRADER_CLIENT_ID"
if ([string]::IsNullOrWhiteSpace($ClientId)) { throw "CTRADER_CLIENT_ID_EMPTY" }
Write-Host "Enter the NEW ROTATED client secret. It will not be printed."
$SecureSecret = Read-Host "CTRADER_CLIENT_SECRET" -AsSecureString
$BSTR=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSecret)
try { $ClientSecret=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR) }
if ([string]::IsNullOrWhiteSpace($ClientSecret)) { throw "CTRADER_CLIENT_SECRET_EMPTY" }
function Set-DotEnvValue([string]$Path,[string]$Name,[string]$Value) {
  $lines=@(); if(Test-Path $Path){$lines=@(Get-Content $Path)}
  $escaped=[regex]::Escape($Name); $found=$false
  $out=foreach($line in $lines){ if($line -match "^\s*$escaped\s*="){$found=$true; "$Name=$Value"}else{$line} }
  if(-not $found){$out += "$Name=$Value"}
  [System.IO.File]::WriteAllLines($Path,[string[]]$out,(New-Object System.Text.UTF8Encoding($false)))
}
Set-DotEnvValue $EnvFile "CTRADER_CLIENT_ID" $ClientId
Set-DotEnvValue $EnvFile "CTRADER_CLIENT_SECRET" $ClientSecret
Set-DotEnvValue $EnvFile "CTRADER_REDIRECT_URI" "https://api.abutronfx.online/v1/ctrader/oauth/callback"
Set-DotEnvValue $EnvFile "CTRADER_OAUTH_SCOPE" "trading"
Set-DotEnvValue $EnvFile "CTRADER_DEMO_EXECUTION_ENABLED" "false"
Set-DotEnvValue $EnvFile "CTRADER_LIVE_MONEY_AUTHORIZED" "false"
Set-DotEnvValue $EnvFile "CTRADER_KILL_SWITCH" "true"
$acl=New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true,$false)
$inherit=[System.Security.AccessControl.InheritanceFlags]::None
$prop=[System.Security.AccessControl.PropagationFlags]::None
$full=[System.Security.AccessControl.FileSystemRights]::FullControl
$allow=[System.Security.AccessControl.AccessControlType]::Allow
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM",$full,$inherit,$prop,$allow)))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators",$full,$inherit,$prop,$allow)))
Set-Acl -Path $EnvFile -AclObject $acl
$ClientSecret=$null; $SecureSecret=$null
Write-Host "STEP23_CREDENTIAL_FILE_UPDATED=True"
Write-Host "CTRADER_REDIRECT_URI=https://api.abutronfx.online/v1/ctrader/oauth/callback"
Write-Host "CTRADER_OAUTH_SCOPE=trading"
Write-Host "CLIENT_SECRET_PRINTED=False"
Write-Host "CTRADER_DEMO_EXECUTION_ENABLED=false"
Write-Host "CTRADER_LIVE_MONEY_AUTHORIZED=false"
Write-Host "CTRADER_KILL_SWITCH=true"
Write-Host "LIVE_MONEY_AUTHORIZED=False"
Write-Host "BROKER_ORDER_SENT=False"
