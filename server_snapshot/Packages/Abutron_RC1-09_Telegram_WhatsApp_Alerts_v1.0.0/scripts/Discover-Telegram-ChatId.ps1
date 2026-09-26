$ErrorActionPreference="Stop"
$envFile="C:\Abutron\Jarvis\rc1_09\.env"
$line=Get-Content $envFile | Where-Object {$_ -match '^RC1_09_TELEGRAM_BOT_TOKEN='} | Select-Object -First 1
if(-not $line){throw "Telegram token missing from RC1-09 .env"}
$token=$line.Substring($line.IndexOf("=")+1).Trim()
if(-not $token){throw "Telegram token is empty"}
$me=Invoke-RestMethod "https://api.telegram.org/bot$token/getMe" -TimeoutSec 20
if(-not $me.ok){throw "Telegram getMe failed"}
Write-Host "BOT_USERNAME=$($me.result.username)"
Write-Host "Send /start to this bot from the Telegram account that should receive Abutron alerts, then run this script again."
$u=Invoke-RestMethod "https://api.telegram.org/bot$token/getUpdates" -TimeoutSec 20
$rows=@()
foreach($x in @($u.result)){
    $m=$x.message
    if(-not $m){$m=$x.channel_post}
    if($m -and $m.chat){
        $rows += [pscustomobject]@{ChatId=$m.chat.id;Type=$m.chat.type;Username=$m.chat.username;FirstName=$m.chat.first_name;Title=$m.chat.title}
    }
}
$rows | Sort-Object ChatId -Unique | Format-Table -AutoSize
Write-Host "Use the numeric ChatId only. Do not enter @username." -ForegroundColor Yellow
