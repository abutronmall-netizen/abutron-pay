param([string]$ChatId="")
$ErrorActionPreference="Stop"
$envFile="C:\Abutron\Jarvis\rc1_09\.env"
if(-not(Test-Path $envFile)){throw "RC1-09 .env not found; install RC1-09 first"}
if($ChatId -and $ChatId -notmatch '^-?\d+$'){throw "ChatId must be numeric"}
$sec=Read-Host "Paste Telegram BotFather token" -AsSecureString
$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try{$token=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
function Set-EnvLine([string]$k,[string]$v){
  $lines=Get-Content $envFile
  $found=$false
  $out=foreach($line in $lines){
    if($line -match ("^"+[regex]::Escape($k)+"=")){ $found=$true; "$k=$v" } else { $line }
  }
  if(-not $found){$out += "$k=$v"}
  Set-Content $envFile $out -Encoding UTF8
}
Set-EnvLine "RC1_09_TELEGRAM_BOT_TOKEN" $token
Set-EnvLine "RC1_09_TELEGRAM_ENABLED" "true"
if($ChatId){Set-EnvLine "RC1_09_TELEGRAM_CHAT_ID" $ChatId}
& icacls $envFile /inheritance:r /grant:r "Administrators:F" "SYSTEM:F" | Out-Null
Write-Host "Telegram token saved securely to restricted RC1-09 .env."
if(-not $ChatId){Write-Host "NEXT: run .\Discover-Telegram-ChatId.ps1, then rerun Configure-Telegram.ps1 -ChatId <numeric-id>" -ForegroundColor Yellow}
else{
  Stop-ScheduledTask -TaskName "Abutron-Jarvis-RC1-09" -ErrorAction SilentlyContinue
  Start-ScheduledTask -TaskName "Abutron-Jarvis-RC1-09"
  Start-Sleep 4
  Write-Host "NEXT: run Test-RC1-09-Transports.ps1 -Telegram" -ForegroundColor Yellow
}
