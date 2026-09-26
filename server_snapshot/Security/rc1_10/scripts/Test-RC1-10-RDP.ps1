param(
    [datetime]$SinceUtc = [datetime]::MinValue,
    [switch]$RequireActiveSession,
    [switch]$FailOnBlocker
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")

Assert-RC10Administrator
$policy = Get-RC10Policy
$findings = New-Object System.Collections.Generic.List[object]

$tsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
$rdpKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"
$ts = Get-ItemProperty $tsKey
$rdp = Get-ItemProperty $rdpKey

if([int]$ts.fDenyTSConnections -eq 0) {
    $findings.Add((New-RC10Finding -Control "RDP_ENABLED" -Status "PASS" -Message "Remote Desktop connections are enabled." -Evidence $null))
} else {
    $findings.Add((New-RC10Finding -Control "RDP_ENABLED" -Status "FAIL" -Message "Remote Desktop connections are disabled." -Evidence $null))
}

$nlaValue = if($rdp.PSObject.Properties["UserAuthentication"]) { [int]$rdp.UserAuthentication } else { -1 }
if($nlaValue -eq 1) {
    $findings.Add((New-RC10Finding -Control "RDP_NLA" -Status "PASS" -Message "Network Level Authentication is required." -Evidence @{UserAuthentication=$nlaValue}))
} else {
    $findings.Add((New-RC10Finding -Control "RDP_NLA" -Status "FAIL" -Message "Network Level Authentication is not required or could not be read." -Evidence @{UserAuthentication=$nlaValue}))
}

$securityLayer = if($rdp.PSObject.Properties["SecurityLayer"]) { [int]$rdp.SecurityLayer } else { -1 }
if($securityLayer -eq 0) {
    $findings.Add((New-RC10Finding -Control "RDP_SECURITY_LAYER" -Status "WARN" -Message "RDP SecurityLayer is set to legacy RDP Security Layer. Review before release." -Evidence @{SecurityLayer=$securityLayer}))
} else {
    $findings.Add((New-RC10Finding -Control "RDP_SECURITY_LAYER" -Status "PASS" -Message "RDP is not forced to the legacy RDP Security Layer." -Evidence @{SecurityLayer=$securityLayer}))
}

$svc = Get-Service TermService -ErrorAction Stop
if($svc.Status -eq "Running") {
    $findings.Add((New-RC10Finding -Control "RDP_SERVICE" -Status "PASS" -Message "Remote Desktop Services is running." -Evidence @{start_type=(Get-CimInstance Win32_Service -Filter "Name='TermService'").StartMode}))
} else {
    $findings.Add((New-RC10Finding -Control "RDP_SERVICE" -Status "FAIL" -Message "Remote Desktop Services is not running." -Evidence @{status=[string]$svc.Status}))
}

$port = if($rdp.PSObject.Properties["PortNumber"]){[int]$rdp.PortNumber}else{3389}
$listener = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object LocalPort -eq $port)
if($listener.Count -gt 0) {
    $findings.Add((New-RC10Finding -Control "RDP_LISTENER" -Status "PASS" -Message "RDP TCP listener is present." -Evidence @{port=$port;addresses=@($listener | Select-Object -ExpandProperty LocalAddress)}))
} else {
    $findings.Add((New-RC10Finding -Control "RDP_LISTENER" -Status "FAIL" -Message "RDP TCP listener is not present." -Evidence @{port=$port}))
}

$sessionText = Get-RC10ActiveRdpText
$activeRdp = ($sessionText -match '(?is)rdp-tcp#.*Active') -or ($sessionText -match '(?is)Active.*rdp-tcp#')
if($activeRdp) {
    $findings.Add((New-RC10Finding -Control "RDP_ACTIVE_SESSION" -Status "PASS" -Message "An active RDP session is visible." -Evidence $null))
} elseif($RequireActiveSession) {
    $findings.Add((New-RC10Finding -Control "RDP_ACTIVE_SESSION" -Status "FAIL" -Message "Final RDP gate requires an active RDP session after reconnect." -Evidence $null))
} else {
    $findings.Add((New-RC10Finding -Control "RDP_ACTIVE_SESSION" -Status "WARN" -Message "No active RDP session was detected during this audit." -Evidence $null))
}

$now = (Get-Date).ToUniversalTime()
if($SinceUtc -eq [datetime]::MinValue) {
    $start = $now.AddHours(-72)
    $strictUnexpected = $false
} else {
    $start = $SinceUtc.ToUniversalTime()
    $strictUnexpected = $true
}
$unexpected = @()
try {
    $unexpected = @(Get-WinEvent -FilterHashtable @{LogName="System";StartTime=$start;Id=41,6008} -ErrorAction SilentlyContinue)
} catch {}
if($unexpected.Count -eq 0) {
    $findings.Add((New-RC10Finding -Control "UNEXPECTED_SHUTDOWN" -Status "PASS" -Message "No unexpected shutdown/power events were found in the evaluated window." -Evidence @{since_utc=$start.ToString("o")}))
} elseif($strictUnexpected) {
    $findings.Add((New-RC10Finding -Control "UNEXPECTED_SHUTDOWN" -Status "FAIL" -Message "Unexpected shutdown/power events occurred after the RC1-10 clean-reboot baseline." -Evidence @{since_utc=$start.ToString("o");count=$unexpected.Count;events=@($unexpected | Select-Object TimeCreated,Id,ProviderName)}))
} else {
    $findings.Add((New-RC10Finding -Control "UNEXPECTED_SHUTDOWN_HISTORY" -Status "WARN" -Message "Historical unexpected shutdown events exist and require a clean post-RC1-10 reboot gate." -Evidence @{since_utc=$start.ToString("o");count=$unexpected.Count;events=@($unexpected | Select-Object TimeCreated,Id,ProviderName)}))
}

$schannel = @()
try {
    $schannel = @(Get-WinEvent -FilterHashtable @{LogName="System";StartTime=$now.AddHours(-24);Id=36874} -ErrorAction SilentlyContinue)
} catch {}
if($schannel.Count -gt 0) {
    $findings.Add((New-RC10Finding -Control "RDP_SCHANNEL_HISTORY" -Status "WARN" -Message "Recent Schannel handshake failures were recorded. Do not weaken TLS/NLA to accommodate unknown clients." -Evidence @{count=$schannel.Count}))
} else {
    $findings.Add((New-RC10Finding -Control "RDP_SCHANNEL_HISTORY" -Status "PASS" -Message "No recent Schannel 36874 events found." -Evidence $null))
}

$fail = @($findings | Where-Object status -eq "FAIL").Count
$warn = @($findings | Where-Object status -eq "WARN").Count
$report = [ordered]@{
    version="1.0.0"
    generated_utc=$now.ToString("o")
    evaluated_since_utc=$start.ToString("o")
    result=if($fail -eq 0){"PASS"}else{"FAIL"}
    fail_count=$fail
    warn_count=$warn
    rdp_port=$port
    active_rdp_session=$activeRdp
    findings=$findings
}
$path = Join-Path $script:RC10Reports ("rdp_"+(Get-RC10Timestamp)+".json")
Write-RC10Json -Path $path -Object $report
Write-Host "RC1_10_RDP_RESULT=$($report.result)"
Write-Host "ACTIVE_RDP_SESSION=$activeRdp"
Write-Host "FAIL_COUNT=$fail WARN_COUNT=$warn"
Write-Host "REPORT=$path"
if($FailOnBlocker -and $fail -gt 0) { throw "RC1-10 RDP controls contain blockers." }
