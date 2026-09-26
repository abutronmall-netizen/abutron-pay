param(
    [int]$Hours = 36,
    [string]$OutRoot = "C:\Abutron\Diagnostics"
)

$ErrorActionPreference = "Continue"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutRoot "MorningLoginHang_$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$txt = Join-Path $outDir "MorningLoginHang_Diagnostic.txt"
$start = (Get-Date).AddHours(-1 * $Hours)

function W([string]$s="") {
    $s | Tee-Object -FilePath $txt -Append
}
function Section([string]$name) {
    W ""
    W ("=" * 78)
    W $name
    W ("=" * 78)
}
function Try-Block([scriptblock]$sb) {
    try { & $sb | Out-String -Width 240 | Tee-Object -FilePath $txt -Append }
    catch { W ("ERROR: " + $_.Exception.Message) }
}

Section "ABUTRON MORNING LOGIN HANG DIAGNOSTIC"
W ("Collected: " + (Get-Date).ToString("o"))
W ("Lookback hours: " + $Hours)
W ("Computer: " + $env:COMPUTERNAME)
W ("User: " + $env:USERNAME)

Section "OPERATING SYSTEM / LAST BOOT"
Try-Block {
    Get-CimInstance Win32_OperatingSystem |
        Select-Object Caption,Version,BuildNumber,LastBootUpTime,
            @{N="FreePhysicalMemoryMB";E={[math]::Round($_.FreePhysicalMemory/1024,1)}}
}

Section "UPTIME"
Try-Block {
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        LastBoot = $os.LastBootUpTime
        UptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours,2)
    }
}

Section "RECENT SHUTDOWN / REBOOT / POWER EVENTS"
Try-Block {
    Get-WinEvent -FilterHashtable @{
        LogName='System'
        Id=41,1074,6005,6006,6008
        StartTime=$start
    } -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object TimeCreated,Id,ProviderName,LevelDisplayName,Message
}

Section "RESOURCE EXHAUSTION / LOW MEMORY"
Try-Block {
    Get-WinEvent -FilterHashtable @{
        LogName='System'
        Id=2004
        StartTime=$start
    } -ErrorAction SilentlyContinue |
    Select-Object TimeCreated,Id,ProviderName,Message
}

Section "DISK / STORAGE / NTFS ERRORS"
Try-Block {
    Get-WinEvent -FilterHashtable @{
        LogName='System'
        StartTime=$start
    } -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProviderName -match 'disk|ntfs|storahci|stornvme|volmgr|volsnap' -or
        $_.Id -in 7,11,15,51,55,57,98,129,153,157
    } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 100 TimeCreated,Id,ProviderName,LevelDisplayName,Message
}

Section "WINDOWS UPDATE EVENTS"
Try-Block {
    Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -ErrorAction Stop |
    Where-Object { $_.TimeCreated -ge $start } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 100 TimeCreated,Id,LevelDisplayName,Message
}

Section "USER PROFILE SERVICE EVENTS"
Try-Block {
    Get-WinEvent -LogName "Microsoft-Windows-User Profiles Service/Operational" -ErrorAction Stop |
    Where-Object { $_.TimeCreated -ge $start } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 100 TimeCreated,Id,LevelDisplayName,Message
}

Section "WINLOGON EVENTS"
Try-Block {
    Get-WinEvent -LogName "Microsoft-Windows-Winlogon/Operational" -ErrorAction Stop |
    Where-Object { $_.TimeCreated -ge $start } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 100 TimeCreated,Id,LevelDisplayName,Message
}

Section "RDP SESSION MANAGER EVENTS"
Try-Block {
    Get-WinEvent -LogName "Microsoft-Windows-TerminalServices-LocalSessionManager/Operational" -ErrorAction Stop |
    Where-Object { $_.TimeCreated -ge $start } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 120 TimeCreated,Id,LevelDisplayName,Message
}

Section "APPLICATION CRASH / HANG EVENTS"
Try-Block {
    Get-WinEvent -FilterHashtable @{
        LogName='Application'
        StartTime=$start
    } -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Id -in 1000,1001,1002 -or
        $_.ProviderName -match 'Application Error|Application Hang|Windows Error Reporting'
    } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 120 TimeCreated,Id,ProviderName,LevelDisplayName,Message
}

Section "PENDING REBOOT INDICATORS"
Try-Block {
    [pscustomobject]@{
        CBS_RebootPending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WU_RebootRequired  = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        PendingFileRenameOperations = [bool](
            Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        )
    }
}

Section "DISK FREE SPACE"
Try-Block {
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{N="SizeGB";E={[math]::Round($_.Size/1GB,2)}},
        @{N="FreeGB";E={[math]::Round($_.FreeSpace/1GB,2)}},
        @{N="FreePct";E={if($_.Size){[math]::Round(($_.FreeSpace/$_.Size)*100,1)}}}
}

Section "PAGEFILE"
Try-Block {
    Get-CimInstance Win32_PageFileUsage |
    Select-Object Name,AllocatedBaseSize,CurrentUsage,PeakUsage
}

Section "TOP MEMORY PROCESSES"
Try-Block {
    Get-Process |
    Sort-Object WorkingSet64 -Descending |
    Select-Object -First 25 Name,Id,
        @{N="RAM_MB";E={[math]::Round($_.WorkingSet64/1MB,1)}},
        CPU,StartTime
}

Section "TOP CPU PROCESSES"
Try-Block {
    Get-Process |
    Sort-Object CPU -Descending |
    Select-Object -First 25 Name,Id,CPU,
        @{N="RAM_MB";E={[math]::Round($_.WorkingSet64/1MB,1)}},
        StartTime
}

Section "CRITICAL SERVICES"
Try-Block {
    Get-Service |
    Where-Object {
        $_.Name -match 'caddy|TermService|ProfSvc|EventLog|Schedule|abutron|kronos|jarvis'
    } |
    Sort-Object Name |
    Select-Object Status,Name,DisplayName,StartType
}

Section "ABUTRON / KRONOS / JARVIS SCHEDULED TASKS"
Try-Block {
    Get-ScheduledTask |
    Where-Object {
        $_.TaskName -match 'Abutron|Kronos|Jarvis|MT5|Trading'
    } |
    ForEach-Object {
        $info = $_ | Get-ScheduledTaskInfo
        [pscustomobject]@{
            TaskName = $_.TaskName
            State = $_.State
            LastRunTime = $info.LastRunTime
            LastTaskResult = $info.LastTaskResult
            NextRunTime = $info.NextRunTime
        }
    } |
    Sort-Object TaskName
}

Section "ABUTRON LISTENING PORTS"
Try-Block {
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in 8088,8090,8091,8765 } |
    Sort-Object LocalPort |
    Select-Object LocalAddress,LocalPort,OwningProcess
}

Section "CURRENT LOGON SESSIONS"
Try-Block {
    quser
}

Section "EXPLORER / WINLOGON / USERINIT PROCESSES"
Try-Block {
    Get-Process explorer,winlogon,userinit,dwm -ErrorAction SilentlyContinue |
    Select-Object Name,Id,SessionId,StartTime,
        @{N="RAM_MB";E={[math]::Round($_.WorkingSet64/1MB,1)}}
}

Section "NETWORK ADAPTERS"
Try-Block {
    Get-NetAdapter |
    Select-Object Name,Status,LinkSpeed,MacAddress,InterfaceDescription
}

Section "RECENT SYSTEM ERRORS / WARNINGS"
Try-Block {
    Get-WinEvent -FilterHashtable @{
        LogName='System'
        Level=1,2,3
        StartTime=$start
    } -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 150 TimeCreated,Id,ProviderName,LevelDisplayName,Message
}

Section "RECENT APPLICATION ERRORS / WARNINGS"
Try-Block {
    Get-WinEvent -FilterHashtable @{
        LogName='Application'
        Level=1,2,3
        StartTime=$start
    } -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 150 TimeCreated,Id,ProviderName,LevelDisplayName,Message
}

Section "END"
W ("Diagnostic folder: " + $outDir)
W ("Report: " + $txt)

$zip = "$outDir.zip"
Compress-Archive -Path (Join-Path $outDir "*") -DestinationPath $zip -Force

Write-Host ""
Write-Host "ABUTRON_MORNING_LOGIN_DIAGNOSTIC=COMPLETE"
Write-Host ("REPORT=" + $txt)
Write-Host ("ZIP=" + $zip)
