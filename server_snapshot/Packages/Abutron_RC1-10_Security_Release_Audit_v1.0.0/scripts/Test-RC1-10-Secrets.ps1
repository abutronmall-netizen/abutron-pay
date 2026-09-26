param([switch]$FailOnBlocker)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")

Assert-RC10Administrator
$policy = Get-RC10Policy
$findings = New-Object System.Collections.Generic.List[object]

$paths = @($policy.secret_env_candidates)
foreach($base in @("C:\Abutron\TradingPlatformV4","C:\Abutron\Jarvis")) {
    if(Test-Path $base) {
        $paths += Get-ChildItem $base -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -in @(".env",".env.production",".env.local") -and
                $_.FullName -notmatch "\\backups\\" -and
                $_.FullName -notmatch "\\Packages\\" -and
                $_.FullName -notmatch "\\node_modules\\" -and
                $_.FullName -notmatch "\\\.venv\\"
            } | Select-Object -ExpandProperty FullName
    }
}
$paths = $paths | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique

$secretKeyRegex = '(?i)(SECRET|TOKEN|PASSWORD|PASSWD|API_KEY|ACCESS_KEY|PRIVATE_KEY)'
$placeholderRegex = '(?i)^(CHANGE_ME|CHANGEME|TODO|YOUR_|EXAMPLE|REPLACE_ME|INSERT_|DUMMY|TEST_SECRET)'
$checkedSecrets = 0

foreach($path in $paths) {
    $acl = Get-Acl $path
    $broad = @($acl.Access | Where-Object {
        ($_.IdentityReference.Value -match '(?i)(Everyone|BUILTIN\\Users|Authenticated Users)') -and
        ($_.FileSystemRights.ToString() -match '(?i)(Read|Write|Modify|FullControl)')
    })
    if(-not $acl.AreAccessRulesProtected -or $broad.Count -gt 0) {
        $findings.Add((New-RC10Finding -Control "SECRET_ACL" -Status "FAIL" -Message "Secret file ACL is inherited or broadly accessible." -Evidence @{path=$path;broad_rule_count=$broad.Count}))
    } else {
        $findings.Add((New-RC10Finding -Control "SECRET_ACL" -Status "PASS" -Message "Secret file ACL is protected." -Evidence @{path=$path}))
    }

    $envMap = Get-RC10EnvMap $path
    foreach($key in @($envMap.Keys)) {
        if($key -match $secretKeyRegex) {
            $checkedSecrets++
            $v = [string]$envMap[$key]
            if($v -and $v -match $placeholderRegex) {
                $findings.Add((New-RC10Finding -Control "SECRET_PLACEHOLDER" -Status "FAIL" -Message "Live secret variable contains a placeholder value." -Evidence @{path=$path;key=$key}))
            } elseif($v -and $v.Length -lt 16) {
                $findings.Add((New-RC10Finding -Control "SECRET_LENGTH" -Status "WARN" -Message "Secret value is shorter than 16 characters; review provider requirements." -Evidence @{path=$path;key=$key;length=$v.Length}))
            }
        }
    }
}


# Plaintext legacy environment copies are release blockers; quarantine them first.
$legacy=@()
foreach($base in @("C:\Abutron\TradingPlatformV4","C:\Abutron\Jarvis")){
    if(Test-Path $base){
        $legacy += Get-ChildItem $base -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '(?i)^\.env\.(before|bak|backup|old|copy)' -and
                $_.FullName -notmatch '\\Security\\rc1_10\\' -and
                $_.FullName -notmatch '\\backups\\' -and
                $_.FullName -notmatch '\\Packages\\' -and
                $_.FullName -notmatch '\\node_modules\\' -and
                $_.FullName -notmatch '\\\.venv\\'
            } | Select-Object -ExpandProperty FullName
    }
}
$legacy=@($legacy | Sort-Object -Unique)
if($legacy.Count -gt 0){
    $findings.Add((New-RC10Finding -Control "LEGACY_SECRET_COPIES" -Status "FAIL" -Message "Plaintext legacy .env copies remain outside the encrypted RC1-10 quarantine." -Evidence @{paths=$legacy}))
}else{
    $findings.Add((New-RC10Finding -Control "LEGACY_SECRET_COPIES" -Status "PASS" -Message "No plaintext legacy .env.before/.bak/.old/.copy files remain in live roots." -Evidence $null))
}

# If a local Git repository exists, production .env files must not be tracked.
foreach($repo in @("C:\Abutron\TradingPlatformV4","C:\Abutron\Jarvis")){
    if(Test-Path (Join-Path $repo ".git")){
        try{
            $tracked=& git -C $repo ls-files 2>$null
            $bad=@($tracked | Where-Object { $_ -match '(?i)(^|/)\.env($|\.)' -and $_ -notmatch '(?i)\.env\.example$' })
            if($bad.Count -gt 0){
                $findings.Add((New-RC10Finding -Control "GIT_SECRET_TRACKING" -Status "FAIL" -Message "A production/legacy .env file is tracked by local Git." -Evidence @{repo=$repo;paths=$bad}))
            }else{
                $findings.Add((New-RC10Finding -Control "GIT_SECRET_TRACKING" -Status "PASS" -Message "No production .env file is tracked by local Git." -Evidence @{repo=$repo}))
            }
        }catch{
            $findings.Add((New-RC10Finding -Control "GIT_SECRET_TRACKING" -Status "WARN" -Message "Git repository exists but tracked-file audit could not run." -Evidence @{repo=$repo;error=$_.Exception.Message}))
        }
    }
}

# Source scan reports path/key only; never secret values.
$hardcoded = @()
$roots = @("C:\Abutron\TradingPlatformV4","C:\Abutron\Jarvis")
$pattern = '(?i)(client_secret|api_token|bot_token|access_token|password)\s*[:=]\s*["''][^"'']{12,}["'']'
foreach($base in $roots) {
    if(-not(Test-Path $base)) { continue }
    $files = Get-ChildItem $base -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -in @(".py",".ps1",".js",".ts",".json",".yaml",".yml") -and
            $_.FullName -notmatch "\\backups\\" -and
            $_.FullName -notmatch "\\Packages\\" -and
            $_.FullName -notmatch "\\logs\\" -and
            $_.FullName -notmatch "\\node_modules\\" -and
            $_.FullName -notmatch "\\\.venv\\"
        }
    foreach($f in $files) {
        $matches = Select-String -Path $f.FullName -Pattern $pattern -AllMatches -ErrorAction SilentlyContinue
        foreach($m in @($matches)) {
            $hardcoded += [pscustomobject]@{path=$f.FullName;line=$m.LineNumber}
        }
    }
}
if($hardcoded.Count -gt 0) {
    $findings.Add((New-RC10Finding -Control "HARDCODED_SECRET_SCAN" -Status "WARN" -Message "Possible hardcoded secret assignments found. Values were not printed; review the listed files." -Evidence $hardcoded))
} else {
    $findings.Add((New-RC10Finding -Control "HARDCODED_SECRET_SCAN" -Status "PASS" -Message "No obvious hardcoded secret assignments found in scanned source." -Evidence $null))
}

$attPath = Join-Path $script:RC10Root "release_attestation.json"
if(Test-Path $attPath) {
    $att = Get-Content $attPath -Raw | ConvertFrom-Json
    if($att.pass -eq $true) {
        $findings.Add((New-RC10Finding -Control "ROTATION_ATTESTATION" -Status "PASS" -Message "Release/secret rotation attestation is present and passing." -Evidence @{created_utc=$att.created_utc}))
    } else {
        $findings.Add((New-RC10Finding -Control "ROTATION_ATTESTATION" -Status "FAIL" -Message "Release attestation is present but not passing." -Evidence $null))
    }
} else {
    $findings.Add((New-RC10Finding -Control "ROTATION_ATTESTATION" -Status "FAIL" -Message "Release/secret rotation attestation is missing." -Evidence $null))
}

$fail = @($findings | Where-Object status -eq "FAIL").Count
$warn = @($findings | Where-Object status -eq "WARN").Count
$report = [ordered]@{
    version="1.0.0"
    generated_utc=(Get-Date).ToUniversalTime().ToString("o")
    files_checked=$paths.Count
    secret_variables_checked=$checkedSecrets
    fail_count=$fail
    warn_count=$warn
    result=if($fail -eq 0){"PASS"}else{"FAIL"}
    findings=$findings
}
$path = Join-Path $script:RC10Reports ("secrets_"+(Get-RC10Timestamp)+".json")
Write-RC10Json -Path $path -Object $report
Write-Host "RC1_10_SECRETS_RESULT=$($report.result)"
Write-Host "FAIL_COUNT=$fail WARN_COUNT=$warn"
Write-Host "REPORT=$path"
if($FailOnBlocker -and $fail -gt 0) { throw "RC1-10 secret controls contain blockers." }
