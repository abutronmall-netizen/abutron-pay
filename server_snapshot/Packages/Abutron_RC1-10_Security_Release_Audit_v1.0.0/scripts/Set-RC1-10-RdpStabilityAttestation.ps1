$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")
Assert-RC10Administrator
$policy=Get-RC10Policy
$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
$uptime=((Get-Date).ToUniversalTime()-$boot).TotalHours
$required=[double]$policy.rdp_stability_hours
$sessionText=Get-RC10ActiveRdpText
$active=(($sessionText -match '(?is)rdp-tcp#.*Active') -or ($sessionText -match '(?is)Active.*rdp-tcp#'))
if($uptime -lt $required){throw ("RDP stability attestation requires at least {0:N2} hours uptime; current {1:N2}." -f $required,$uptime)}
if(-not $active){throw "RDP stability attestation must be run from/while a normal active RDP session is present."}
function Ask-YesNo([string]$Prompt){
    while($true){$r=(Read-Host "$Prompt [Y/N]").Trim().ToUpperInvariant();if($r -eq 'Y'){return $true};if($r -eq 'N'){return $false}}
}
Write-Host "=== RC1-10 RDP STABILITY ATTESTATION ===" -ForegroundColor Yellow
$overnight=Ask-YesNo "Did this server remain up through the normal unattended/overnight period without a manual power reset?"
$normalLogin=Ask-YesNo "Did normal RDP login/reconnect succeed without first rebooting the VPS?"
$noConsoleReset=Ask-YesNo "Was no provider-console hard reset required to obtain this RDP session?"
$pass=$overnight -and $normalLogin -and $noConsoleReset
$obj=[ordered]@{
 version="1.0.0";created_utc=(Get-Date).ToUniversalTime().ToString("o");boot_utc=$boot.ToString("o");uptime_hours=[math]::Round($uptime,2);
 unattended_period_without_manual_reset=$overnight;normal_rdp_login_succeeded=$normalLogin;provider_console_hard_reset_not_required=$noConsoleReset;pass=$pass
}
$path=Join-Path $script:RC10Root "rdp_stability_attestation.json"
Write-RC10Json -Path $path -Object $obj
if(-not $pass){throw "RDP stability attestation did not pass."}
Write-Host "RC1_10_RDP_STABILITY_ATTESTATION=PASS" -ForegroundColor Green
Write-Host "ATTESTATION=$path"
