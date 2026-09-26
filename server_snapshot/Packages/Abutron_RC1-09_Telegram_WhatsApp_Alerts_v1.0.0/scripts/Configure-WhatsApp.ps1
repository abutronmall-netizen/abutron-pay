param(
 [Parameter(Mandatory=$true)][string]$PhoneNumberId,
 [Parameter(Mandatory=$true)][string]$Recipient,
 [Parameter(Mandatory=$true)][string]$GraphVersion,
 [string]$TemplateName="abutron_system_alert",
 [string]$TemplateLanguage="en_US"
)
$ErrorActionPreference="Stop"
$envFile="C:\Abutron\Jarvis\rc1_09\.env"
if(-not(Test-Path $envFile)){throw "RC1-09 .env not found"}
$recipient=($Recipient -replace '\D','')
if(-not $recipient){throw "Recipient must contain a country-code phone number"}
$tokSec=Read-Host "Paste Meta system-user access token" -AsSecureString
$appSec=Read-Host "Paste Meta App Secret (for webhook signature verification)" -AsSecureString
$verifySec=Read-Host "Create/paste a strong webhook verify token" -AsSecureString
function Reveal($s){$p=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s);try{[Runtime.InteropServices.Marshal]::PtrToStringBSTR($p)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p)}}
$token=Reveal $tokSec; $app=Reveal $appSec; $verify=Reveal $verifySec
function Set-EnvLine([string]$k,[string]$v){
  $lines=Get-Content $envFile; $found=$false
  $out=foreach($line in $lines){if($line -match ("^"+[regex]::Escape($k)+"=")){$found=$true;"$k=$v"}else{$line}}
  if(-not $found){$out += "$k=$v"}; Set-Content $envFile $out -Encoding UTF8
}
Set-EnvLine "RC1_09_WHATSAPP_ENABLED" "true"
Set-EnvLine "RC1_09_WHATSAPP_ACCESS_TOKEN" $token
Set-EnvLine "RC1_09_WHATSAPP_PHONE_NUMBER_ID" $PhoneNumberId
Set-EnvLine "RC1_09_WHATSAPP_RECIPIENT" $recipient
Set-EnvLine "RC1_09_META_GRAPH_VERSION" $GraphVersion
Set-EnvLine "RC1_09_WHATSAPP_MODE" "template"
Set-EnvLine "RC1_09_WHATSAPP_TEMPLATE_NAME" $TemplateName
Set-EnvLine "RC1_09_WHATSAPP_TEMPLATE_LANGUAGE" $TemplateLanguage
Set-EnvLine "RC1_09_WHATSAPP_VERIFY_TOKEN" $verify
Set-EnvLine "RC1_09_META_APP_SECRET" $app
& icacls $envFile /inheritance:r /grant:r "Administrators:F" "SYSTEM:F" | Out-Null
Stop-ScheduledTask -TaskName "Abutron-Jarvis-RC1-09" -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName "Abutron-Jarvis-RC1-09"
Start-Sleep 4
Write-Host "WhatsApp/Meta configuration saved. Secrets were not printed." -ForegroundColor Green
Write-Host "NEXT: run Patch-Caddy-WhatsApp-Webhook.ps1 then configure the Meta webhook callback." -ForegroundColor Yellow
