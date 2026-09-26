param([switch]$FailOnBlocker)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")

Assert-RC10Administrator
$state = Assert-RC10ReleaseSafety
$os = Get-CimInstance Win32_OperatingSystem
$findings = New-Object System.Collections.Generic.List[object]

$findings.Add((New-RC10Finding -Control "OS" -Status "INFO" -Message "Operating system captured." -Evidence @{caption=$os.Caption;version=$os.Version;build=$os.BuildNumber;last_boot=$os.LastBootUpTime.ToUniversalTime().ToString("o")}))

$taskRows = @()
$policy = Get-RC10Policy
foreach($name in @($policy.critical_tasks)) {
    $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if($t) {
        $taskRows += [pscustomobject]@{name=$name;state=[string]$t.State}
        if($t.State -eq "Running") {
            $findings.Add((New-RC10Finding -Control "TASK_$name" -Status "PASS" -Message "Critical scheduled task is Running." -Evidence @{state=[string]$t.State}))
        } else {
            $findings.Add((New-RC10Finding -Control "TASK_$name" -Status "WARN" -Message "Critical scheduled task is not currently Running; health endpoints remain authoritative." -Evidence @{state=[string]$t.State}))
        }
    } else {
        $findings.Add((New-RC10Finding -Control "TASK_$name" -Status "FAIL" -Message "Critical scheduled task is missing." -Evidence $null))
    }
}

# AutoAdminLogon is recorded as a blocker because it stores/uses credentials in a way that must be explicitly justified.
$wl = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$autoAdmin = if($wl.PSObject.Properties["AutoAdminLogon"]) { [string]$wl.AutoAdminLogon } else { "0" }
if($autoAdmin -eq "1") {
    $findings.Add((New-RC10Finding -Control "AUTOADMINLOGON" -Status "FAIL" -Message "AutoAdminLogon is enabled. Do not disable it blindly; determine whether MT5 depends on it, then replace with a safer startup design before release." -Evidence $null))
} else {
    $findings.Add((New-RC10Finding -Control "AUTOADMINLOGON" -Status "PASS" -Message "AutoAdminLogon is not enabled." -Evidence $null))
}

# Guest should remain disabled.
try {
    $guest = Get-LocalUser -Name "Guest" -ErrorAction Stop
    if($guest.Enabled) {
        $findings.Add((New-RC10Finding -Control "GUEST_ACCOUNT" -Status "FAIL" -Message "Built-in Guest account is enabled." -Evidence $null))
    } else {
        $findings.Add((New-RC10Finding -Control "GUEST_ACCOUNT" -Status "PASS" -Message "Built-in Guest account is disabled." -Evidence $null))
    }
} catch {
    $findings.Add((New-RC10Finding -Control "GUEST_ACCOUNT" -Status "INFO" -Message "Built-in Guest account could not be queried by name." -Evidence @{error=$_.Exception.Message}))
}

$fail = @($findings | Where-Object status -eq "FAIL").Count
$warn = @($findings | Where-Object status -eq "WARN").Count
$report = [ordered]@{
    version="1.0.0"
    generated_utc=(Get-Date).ToUniversalTime().ToString("o")
    result=if($fail -eq 0){"PASS"}else{"FAIL"}
    fail_count=$fail
    warn_count=$warn
    safety=[ordered]@{
        execution_enabled=$state.core.execution_enabled
        mt5_live_trading=$state.core.mt5.live_trading
        mt5_management_enabled=$state.core.mt5.management_enabled
        rc1_08_mode=$state.rc1_08.mode
        rc1_09_mode=$state.rc1_09.mode
        telegram_enabled=$state.rc1_09.channels.telegram
        whatsapp_enabled=$state.rc1_09.channels.whatsapp
    }
    tasks=$taskRows
    findings=$findings
}
$path = Join-Path $script:RC10Reports ("preflight_"+(Get-RC10Timestamp)+".json")
Write-RC10Json -Path $path -Object $report
Write-Host "RC1_10_PREFLIGHT_RESULT=$($report.result)"
Write-Host "FAIL_COUNT=$fail WARN_COUNT=$warn"
Write-Host "REPORT=$path"
if($FailOnBlocker -and $fail -gt 0) { throw "RC1-10 preflight contains blockers." }
