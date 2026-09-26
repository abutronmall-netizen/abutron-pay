param([switch]$FailOnBlocker)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")

Assert-RC10Administrator
$policy = Get-RC10Policy
$findings = New-Object System.Collections.Generic.List[object]

# Windows Firewall must be enabled and must not use Allow as the default inbound policy.
$profiles = @(Get-NetFirewallProfile)
foreach($p in $profiles) {
    if($p.Enabled -ne $true) {
        $findings.Add((New-RC10Finding -Control "FIREWALL_$($p.Name)" -Status "FAIL" -Message "Windows Firewall profile is disabled." -Evidence @{profile=$p.Name}))
    } elseif($p.DefaultInboundAction -eq "Allow") {
        $findings.Add((New-RC10Finding -Control "FIREWALL_$($p.Name)" -Status "FAIL" -Message "Windows Firewall default inbound action is Allow." -Evidence @{profile=$p.Name;default_inbound=[string]$p.DefaultInboundAction}))
    } else {
        $findings.Add((New-RC10Finding -Control "FIREWALL_$($p.Name)" -Status "PASS" -Message "Firewall profile is enabled and does not default to inbound Allow." -Evidence @{profile=$p.Name;default_inbound=[string]$p.DefaultInboundAction}))
    }
}

# Sensitive Abutron/admin/monitoring ports must be loopback-only.
$listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue)
foreach($port in @($policy.sensitive_loopback_ports)) {
    $rows = @($listeners | Where-Object LocalPort -eq [int]$port)
    foreach($row in $rows) {
        if(Test-RC10LoopbackAddress ([string]$row.LocalAddress)) {
            $findings.Add((New-RC10Finding -Control "LOOPBACK_PORT_$port" -Status "PASS" -Message "Sensitive port is loopback-bound." -Evidence @{address=$row.LocalAddress;port=$port;pid=$row.OwningProcess}))
        } else {
            $findings.Add((New-RC10Finding -Control "LOOPBACK_PORT_$port" -Status "FAIL" -Message "Sensitive port is listening beyond loopback." -Evidence @{address=$row.LocalAddress;port=$port;pid=$row.OwningProcess}))
        }
    }
}

# Caddy must be running.
try {
    $caddySvc = Get-Service caddy -ErrorAction Stop
    if($caddySvc.Status -eq "Running") {
        $findings.Add((New-RC10Finding -Control "CADDY_SERVICE" -Status "PASS" -Message "Caddy service is running." -Evidence @{start_type=(Get-CimInstance Win32_Service -Filter "Name='caddy'").StartMode}))
    } else {
        $findings.Add((New-RC10Finding -Control "CADDY_SERVICE" -Status "FAIL" -Message "Caddy service is not running." -Evidence @{status=[string]$caddySvc.Status}))
    }
} catch {
    $findings.Add((New-RC10Finding -Control "CADDY_SERVICE" -Status "FAIL" -Message "Caddy service was not found." -Evidence $null))
}

$caddyExe = "C:\caddy\caddy.exe"
$caddyFile = "C:\caddy\Caddyfile"
if((Test-Path $caddyExe) -and (Test-Path $caddyFile)) {
    & $caddyExe validate --config $caddyFile --adapter caddyfile | Out-Null
    if($LASTEXITCODE -eq 0) {
        $findings.Add((New-RC10Finding -Control "CADDY_VALIDATE" -Status "PASS" -Message "Active Caddy configuration validates." -Evidence $null))
    } else {
        $findings.Add((New-RC10Finding -Control "CADDY_VALIDATE" -Status "FAIL" -Message "Active Caddy configuration failed validation." -Evidence $null))
    }
}

$hostName = [string]$policy.public_https_host
$healthUri = "https://$hostName$($policy.public_health_path)"
try {
    $r = Invoke-WebRequest -Uri $healthUri -UseBasicParsing -TimeoutSec 20
    if([int]$r.StatusCode -eq 200) {
        $findings.Add((New-RC10Finding -Control "PUBLIC_HEALTHZ" -Status "PASS" -Message "Public minimal health endpoint returns 200." -Evidence @{uri=$healthUri}))
    } else {
        $findings.Add((New-RC10Finding -Control "PUBLIC_HEALTHZ" -Status "FAIL" -Message "Public minimal health endpoint did not return 200." -Evidence @{uri=$healthUri;status=[int]$r.StatusCode}))
    }
} catch {
    $findings.Add((New-RC10Finding -Control "PUBLIC_HEALTHZ" -Status "FAIL" -Message "Public HTTPS health check failed." -Evidence @{uri=$healthUri;error=$_.Exception.Message}))
}

foreach($x in @($policy.public_blocked)) {
    $uri = "https://$hostName$($x.path)"
    $code = $null
    try {
        $r = Invoke-WebRequest -Uri $uri -Method ([string]$x.method) -UseBasicParsing -TimeoutSec 20
        $code = [int]$r.StatusCode
    } catch {
        if($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $code = [int]$_.Exception.Response.StatusCode
        }
    }
    if($code -eq 404) {
        $findings.Add((New-RC10Finding -Control "PUBLIC_DENY" -Status "PASS" -Message "Sensitive public route is default-denied." -Evidence @{method=$x.method;path=$x.path;status=$code}))
    } else {
        $findings.Add((New-RC10Finding -Control "PUBLIC_DENY" -Status "FAIL" -Message "Sensitive route did not return the expected public default-deny response." -Evidence @{method=$x.method;path=$x.path;status=$code}))
    }
}

# Validate public TLS chain/hostname and certificate lifetime through SslStream.
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect($hostName,443)
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(),$false)
    $ssl.AuthenticateAsClient($hostName)
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
    $days = [math]::Floor(($cert.NotAfter.ToUniversalTime() - (Get-Date).ToUniversalTime()).TotalDays)
    if($days -ge [int]$policy.minimum_tls_certificate_days_remaining) {
        $findings.Add((New-RC10Finding -Control "TLS_CERTIFICATE" -Status "PASS" -Message "TLS certificate chain/hostname validation succeeded with sufficient lifetime." -Evidence @{subject=$cert.Subject;issuer=$cert.Issuer;not_after=$cert.NotAfter.ToUniversalTime().ToString("o");days_remaining=$days}))
    } else {
        $findings.Add((New-RC10Finding -Control "TLS_CERTIFICATE" -Status "FAIL" -Message "TLS certificate is too close to expiry." -Evidence @{not_after=$cert.NotAfter.ToUniversalTime().ToString("o");days_remaining=$days}))
    }
    $ssl.Dispose(); $tcp.Dispose()
} catch {
    $findings.Add((New-RC10Finding -Control "TLS_CERTIFICATE" -Status "FAIL" -Message "TLS handshake/certificate validation failed." -Evidence @{error=$_.Exception.Message}))
}

$fail = @($findings | Where-Object status -eq "FAIL").Count
$warn = @($findings | Where-Object status -eq "WARN").Count
$report = [ordered]@{
    version="1.0.0"
    generated_utc=(Get-Date).ToUniversalTime().ToString("o")
    result=if($fail -eq 0){"PASS"}else{"FAIL"}
    fail_count=$fail
    warn_count=$warn
    findings=$findings
}
$path = Join-Path $script:RC10Reports ("network_tls_"+(Get-RC10Timestamp)+".json")
Write-RC10Json -Path $path -Object $report
Write-Host "RC1_10_NETWORK_TLS_RESULT=$($report.result)"
Write-Host "FAIL_COUNT=$fail WARN_COUNT=$warn"
Write-Host "REPORT=$path"
if($FailOnBlocker -and $fail -gt 0) { throw "RC1-10 network/TLS controls contain blockers." }
