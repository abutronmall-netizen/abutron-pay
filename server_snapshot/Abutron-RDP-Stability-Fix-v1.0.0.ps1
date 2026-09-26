param(
    [string]$BackupRoot = "C:\Abutron\Backups\RDP-Stability"
)

$ErrorActionPreference = "Stop"

function Say([string]$s) { Write-Host $s }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Path $backup -Force | Out-Null

Say "ABUTRON_RDP_STABILITY_FIX_V1_0_0_START"

# Safety: require elevation.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "RUN_AS_ADMINISTRATOR_REQUIRED"
}
Say "ELEVATION=PASS"

# Capture current state.
$report = Join-Path $backup "before.txt"
@(
    "Collected: $(Get-Date -Format o)"
    ""
    "=== OS ==="
    (Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,BuildNumber,LastBootUpTime | Out-String)
    "=== RDP POLICY KEY ==="
    (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -ErrorAction SilentlyContinue | Out-String)
    "=== TERMINAL SERVER KEY ==="
    (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -ErrorAction SilentlyContinue | Out-String)
    "=== CURRENT SESSIONS ==="
    ((quser 2>&1) | Out-String)
    "=== PAGEFILE ==="
    (Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Out-String)
) | Set-Content $report -Encoding UTF8

# Registry backups.
& reg.exe export "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" `
    (Join-Path $backup "TerminalServices-Policy.reg") /y | Out-Null
& reg.exe export "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" `
    (Join-Path $backup "TerminalServer-Control.reg") /y | Out-Null
Say "REGISTRY_BACKUP=PASS"

# 1) Force RDP server transport to TCP only.
# Microsoft ADMX mapping: SelectTransport=1 => Use only TCP.
$policy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
New-Item -Path $policy -Force | Out-Null
New-ItemProperty -Path $policy -Name "SelectTransport" -PropertyType DWord -Value 1 -Force | Out-Null
Say "RDP_TRANSPORT_TCP_ONLY=SET"

# 2) Restrict each user to one RDP session so reconnects reuse the existing session.
New-ItemProperty -Path $policy -Name "fSingleSessionPerUser" -PropertyType DWord -Value 1 -Force | Out-Null
Say "RDP_SINGLE_SESSION_PER_USER=SET"

# Also set the control-level value used by Terminal Services.
$ts = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
New-ItemProperty -Path $ts -Name "fSingleSessionPerUser" -PropertyType DWord -Value 1 -Force | Out-Null

# 3) Enable RDP keep-alive. Do NOT restart TermService after this.
New-ItemProperty -Path $ts -Name "KeepAliveEnable" -PropertyType DWord -Value 1 -Force | Out-Null
New-ItemProperty -Path $ts -Name "KeepAliveInterval" -PropertyType DWord -Value 1 -Force | Out-Null
Say "RDP_KEEPALIVE=SET"

# 4) Use a system-managed pagefile instead of the observed 1 GB fixed allocation.
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    Set-CimInstance -InputObject $cs -Property @{AutomaticManagedPagefile=$true} | Out-Null
    Say "PAGEFILE_SYSTEM_MANAGED=SET"
}
catch {
    Say ("PAGEFILE_SYSTEM_MANAGED=WARNING:{0}" -f $_.Exception.Message)
}

# Apply policy registration, but intentionally do not restart TermService.
& gpupdate.exe /target:computer /force | Out-Host
Say "GROUP_POLICY_REFRESH=COMPLETE"

# Verify settings written.
$verify = [pscustomobject]@{
    SelectTransport = (Get-ItemPropertyValue -Path $policy -Name "SelectTransport")
    fSingleSessionPerUser_Policy = (Get-ItemPropertyValue -Path $policy -Name "fSingleSessionPerUser")
    fSingleSessionPerUser_Control = (Get-ItemPropertyValue -Path $ts -Name "fSingleSessionPerUser")
    KeepAliveEnable = (Get-ItemPropertyValue -Path $ts -Name "KeepAliveEnable")
    KeepAliveInterval = (Get-ItemPropertyValue -Path $ts -Name "KeepAliveInterval")
    AutomaticManagedPagefile = (Get-CimInstance Win32_ComputerSystem).AutomaticManagedPagefile
}
$verify | Format-List | Out-Host
$verify | ConvertTo-Json | Set-Content (Join-Path $backup "after.json") -Encoding UTF8

if($verify.SelectTransport -ne 1) { throw "VERIFY_SELECT_TRANSPORT_FAIL" }
if($verify.fSingleSessionPerUser_Policy -ne 1) { throw "VERIFY_SINGLE_SESSION_POLICY_FAIL" }
if($verify.fSingleSessionPerUser_Control -ne 1) { throw "VERIFY_SINGLE_SESSION_CONTROL_FAIL" }
if($verify.KeepAliveEnable -ne 1) { throw "VERIFY_KEEPALIVE_ENABLE_FAIL" }
if($verify.KeepAliveInterval -ne 1) { throw "VERIFY_KEEPALIVE_INTERVAL_FAIL" }

Say "RDP_STABILITY_SETTINGS=PASS"
Say "TERM_SERVICE_RESTARTED=False"
Say "ABUTRON_EXECUTION_CHANGED=False"
Say "REBOOT_REQUIRED=True"
Say ("BACKUP=" + $backup)
Say "ABUTRON_RDP_STABILITY_FIX_V1_0_0=PASS"
