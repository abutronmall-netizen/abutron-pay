$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")

$state = Assert-RC10ReleaseSafety
$pre = Get-RC10LatestFile -Directory $script:RC10Certification -Filter "RC1_10_PRE_REBOOT_*.json"
$post = Get-RC10LatestFile -Directory $script:RC10Certification -Filter "RC1_10_POST_REBOOT_*.json"
$final = Get-RC10LatestFile -Directory $script:RC10Certification -Filter "RC1_10_FINAL_*.json"
[pscustomobject]@{
    CoreExecutionEnabled=$state.core.execution_enabled
    Mt5LiveTrading=$state.core.mt5.live_trading
    RC108Mode=$state.rc1_08.mode
    RC109Mode=$state.rc1_09.mode
    Telegram=$state.rc1_09.channels.telegram
    WhatsApp=$state.rc1_09.channels.whatsapp
    PreRebootCertificate=if($pre){$pre.FullName}else{$null}
    PostRebootCertificate=if($post){$post.FullName}else{$null}
    FinalCertificate=if($final){$final.FullName}else{$null}
} | Format-List
