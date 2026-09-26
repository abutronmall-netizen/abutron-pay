$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")
Assert-RC10Administrator

function Ask-YesNo([string]$Prompt) {
    while($true) {
        $r = (Read-Host "$Prompt [Y/N]").Trim().ToUpperInvariant()
        if($r -eq "Y") { return $true }
        if($r -eq "N") { return $false }
    }
}

Write-Host "=== RC1-10 RELEASE ATTESTATION ===" -ForegroundColor Yellow
Write-Host "Do NOT paste or enter any secret value. This records yes/no release evidence only."

$spotwareRotated = Ask-YesNo "Has the previously exposed cTrader/Spotware client secret been replaced/rotated?"
$oldRevoked = Ask-YesNo "Is the previously exposed cTrader/Spotware secret no longer used by the production gateway?"
$telegramPrivate = Ask-YesNo "Has the Telegram bot token remained private (masked secure prompt only), or been rotated if exposure was suspected?"
$noPublicSecrets = Ask-YesNo "Have you verified production secrets are not committed to a public/shared source repository or pasted into public documents?"
$providerConsole = Ask-YesNo "Can you access the VPS provider console/rescue path if RDP fails?"
$offHostBackup = Ask-YesNo "Has a current provider snapshot or other off-host backup been created for this RC state?"
$whatsappDeferred = Ask-YesNo "Is WhatsApp/Meta intentionally disabled/deferred for RC1-09?"

$all = $spotwareRotated -and $oldRevoked -and $telegramPrivate -and $noPublicSecrets -and $providerConsole -and $offHostBackup -and $whatsappDeferred

$obj = [ordered]@{
    version="1.0.0"
    created_utc=(Get-Date).ToUniversalTime().ToString("o")
    spotware_client_secret_rotated=$spotwareRotated
    old_spotware_secret_not_in_use=$oldRevoked
    telegram_token_private_or_rotated=$telegramPrivate
    no_public_source_secrets=$noPublicSecrets
    provider_console_or_rescue_verified=$providerConsole
    off_host_backup_or_provider_snapshot_created=$offHostBackup
    whatsapp_meta_deferred=$whatsappDeferred
    pass=$all
}
$path = Join-Path $script:RC10Root "release_attestation.json"
Write-RC10Json -Path $path -Object $obj
if(-not $all) { throw "RC1-10 release attestation has one or more NO answers. Resolve them before certification." }
Write-Host "RC1_10_RELEASE_ATTESTATION=PASS" -ForegroundColor Green
Write-Host "ATTESTATION=$path"
