$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")
Assert-RC10Administrator

$os = Get-CimInstance Win32_OperatingSystem
$module = Get-Module -ListAvailable -Name Microsoft.OSConfig | Select-Object -First 1
$report = [ordered]@{
    version="1.0.0"
    generated_utc=(Get-Date).ToUniversalTime().ToString("o")
    os_caption=$os.Caption
    os_build=$os.BuildNumber
    osconfig_module_present=[bool]$module
    osconfig_module_version=if($module){[string]$module.Version}else{$null}
    automatic_baseline_application=$false
    decision="ADVISORY_ONLY_DURING_RC_FREEZE"
    reason="The Microsoft Windows Server 2025 baseline is role-aware and can modify firewall, RDP redirection, SMB and cryptography settings. RC1-10 audits release-critical controls but does not auto-apply the complete baseline on a remote trading server."
}
$path=Join-Path $script:RC10Reports ("microsoft_baseline_readiness_"+(Get-RC10Timestamp)+".json")
Write-RC10Json -Path $path -Object $report
Write-Host "RC1_10_MICROSOFT_BASELINE_MODE=ADVISORY_ONLY"
Write-Host "REPORT=$path"
