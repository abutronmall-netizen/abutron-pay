[CmdletBinding()]
param(
    [ValidateSet('PRECHECK','DEMO')]
    [string]$Mode = 'PRECHECK',

    [ValidateSet('ALL','FLIPPER','SCALPER','MASTER')]
    [string]$Tier = 'ALL',

    [ValidateSet('BUY','SELL')]
    [string]$Direction = 'BUY',

    [long]$ScalperLogin = 0,
    [long]$MasterLogin = 0,

    [switch]$AuthorizeDemo,

    [string]$Root = 'C:\Abutron\TradingPlatformV4',
    [string]$CoreUrl = 'http://127.0.0.1:8088',
    [string]$BridgeUrl = 'http://127.0.0.1:8090'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BuildMarker = 'STEP21_CONTROLLED_DEMO_EXECUTION_CERT_V1_0'
$ScriptDir = Join-Path $Root 'scripts'
$LogDir = Join-Path $Root 'logs'
$EnvFile = Join-Path $Root '.env'
$FlipperRunner = Join-Path $ScriptDir 'Abutron-Step19-Equity-Router-Bot-Lifecycle-Cert.ps1'
$MultiRunner = Join-Path $ScriptDir 'Abutron-Step19-MultiDemo-Cert-v1.4.ps1'
$MultiHelper = Join-Path $ScriptDir 'step19_multi_demo_cert_v1_4.py'
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$ControllerLog = Join-Path $LogDir "step21_controller_${RunStamp}.log"
$SummaryFile = Join-Path $LogDir "step21_summary_${RunStamp}.json"
$StableSummaryFile = Join-Path $LogDir 'step21_certification.json'
$StartedUtc = [DateTime]::UtcNow

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

function Write-Step21 {
    param([string]$Message)
    $line = "{0} {1}" -f ([DateTime]::UtcNow.ToString('o')), $Message
    Write-Host $Message
    Add-Content -Path $ControllerLog -Value $line -Encoding UTF8
}

function Get-EnvValue {
    param([string]$Name)
    if (-not (Test-Path $EnvFile)) { throw "Missing production env file: $EnvFile" }
    $escaped = [regex]::Escape($Name)
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^\s*$escaped\s*=" } | Select-Object -First 1
    if (-not $line) { return $null }
    $value = ($line -split '=',2)[1].Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        $value = $value.Substring(1,$value.Length-2)
    }
    return $value
}

function Assert-EnvFalse {
    param([string]$Name)
    $v = Get-EnvValue $Name
    if ($null -eq $v) { throw "$Name missing from .env" }
    if ($v.ToString().ToLowerInvariant() -ne 'false') { throw "$Name must remain false for Step21; actual=$v" }
    Write-Step21 "$Name=OFF"
}

function Assert-EnvTrue {
    param([string]$Name)
    $v = Get-EnvValue $Name
    if ($null -eq $v) { throw "$Name missing from .env" }
    if ($v.ToString().ToLowerInvariant() -ne 'true') { throw "$Name must be true for Step21; actual=$v" }
    Write-Step21 "$Name=True"
}

function Get-WorkerCount {
    $items = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and ($_.CommandLine -match 'abutron\.worker' -or $_.CommandLine -match 'python.+worker\.py')
    })
    return $items.Count
}

function Invoke-JsonGet {
    param([string]$Url,[hashtable]$Headers=$null)
    if ($Headers) { return Invoke-RestMethod -Method Get -Uri $Url -Headers $Headers -TimeoutSec 20 }
    return Invoke-RestMethod -Method Get -Uri $Url -TimeoutSec 20
}

function Invoke-PowerShellChild {
    param(
        [Parameter(Mandatory=$true)][string]$Runner,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [Parameter(Mandatory=$true)][string]$Name
    )
    if (-not (Test-Path $Runner)) { throw "Required child runner missing: $Runner" }

    $stdout = Join-Path $LogDir ("step21_{0}_{1}_stdout.log" -f $Name,$RunStamp)
    $stderr = Join-Path $LogDir ("step21_{0}_{1}_stderr.log" -f $Name,$RunStamp)

    $quoted = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $Runner))
    foreach ($a in $Arguments) {
        if ($a -match '\s') { $quoted += ('"{0}"' -f ($a -replace '"','\"')) }
        else { $quoted += $a }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $outText = $p.StandardOutput.ReadToEnd()
    $errText = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    [System.IO.File]::WriteAllText($stdout,$outText,[System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($stderr,$errText,[System.Text.UTF8Encoding]::new($false))

    foreach ($line in ($outText -split "`r?`n")) { if ($line) { Write-Host $line } }
    foreach ($line in ($errText -split "`r?`n")) { if ($line) { Write-Host $line } }

    Add-Content -Path $ControllerLog -Value "--- CHILD $Name STDOUT ---" -Encoding UTF8
    Add-Content -Path $ControllerLog -Value $outText -Encoding UTF8
    if ($errText) {
        Add-Content -Path $ControllerLog -Value "--- CHILD $Name STDERR ---" -Encoding UTF8
        Add-Content -Path $ControllerLog -Value $errText -Encoding UTF8
    }

    return [pscustomobject]@{
        ExitCode = [int]$p.ExitCode
        Output = ($outText + "`n" + $errText)
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Assert-Contains {
    param([string]$Text,[string]$Pattern,[string]$Gate)
    if ($Text -notmatch $Pattern) { throw "$Gate failed; expected pattern not found: $Pattern" }
    Write-Step21 "$Gate=PASS"
}

function Assert-Step20Prerequisite {
    $latest = Get-ChildItem $LogDir -Filter 'step20_summary_*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { throw 'No Step20 summary found.' }
    $s = Get-Content $latest.FullName -Raw | ConvertFrom-Json
    if ($s.result -ne 'PASS') { throw "Latest Step20 result is not PASS: $($s.result)" }
    if ([double]$s.observed_minutes -lt 120.0) { throw "Step20 duration below 120 minutes: $($s.observed_minutes)" }
    if ([bool]$s.live_money_authorized) { throw 'Step20 artifact says live money authorized; refusing Step21.' }
    Write-Step21 "STEP20_PREREQUISITE=PASS"
    Write-Step21 "STEP20_OBSERVED_MINUTES=$($s.observed_minutes)"
    return $latest.FullName
}

function Assert-LiveStackSafety {
    $core = Invoke-JsonGet "$CoreUrl/health"
    $bridge = Invoke-JsonGet "$BridgeUrl/health"

    if ($core.status -ne 'ok') { throw "Core health not ok: $($core.status)" }
    if ($null -ne $core.execution_enabled -and [bool]$core.execution_enabled) { throw 'Core reports execution_enabled=True.' }
    if ($null -ne $bridge.live_trading -and [bool]$bridge.live_trading) { throw 'Bridge reports live_trading=True.' }
    if ($null -ne $bridge.management_enabled -and [bool]$bridge.management_enabled) { throw 'Bridge reports management_enabled=True.' }
    if ($null -ne $bridge.mt5_connected -and -not [bool]$bridge.mt5_connected) { throw 'Bridge reports MT5 disconnected.' }

    Write-Step21 'CORE_HEALTH=PASS'
    Write-Step21 'BRIDGE_HEALTH=PASS'
    Write-Step21 'LIVE_STACK_EXECUTION_LOCK=PASS'
}

function Invoke-TierCertification {
    param([string]$TargetTier,[long]$CertLogin)

    $runner = $FlipperRunner
    $preArgs = @('-Mode','PRECHECK','-RequireTier',$TargetTier)
    $demoArgs = @('-Mode','DEMO','-RequireTier',$TargetTier,'-Direction',$Direction,'-AuthorizeDemo')

    if ($TargetTier -in @('SCALPER','MASTER')) {
        $runner = $MultiRunner
        if ($CertLogin -le 0) { throw "$TargetTier requires a certification DEMO login." }
        $preArgs = @('-Mode','PRECHECK','-RequireTier',$TargetTier,'-CertLogin',$CertLogin.ToString())
        $demoArgs = @('-Mode','DEMO','-RequireTier',$TargetTier,'-CertLogin',$CertLogin.ToString(),'-Direction',$Direction,'-AuthorizeDemo')
    }

    Write-Step21 "STEP21_${TargetTier}_PRECHECK=START"
    $pre = Invoke-PowerShellChild -Runner $runner -Arguments $preArgs -Name ("{0}_precheck" -f $TargetTier.ToLowerInvariant())
    if ($pre.ExitCode -ne 0) { throw "$TargetTier precheck child exit=$($pre.ExitCode)" }
    Assert-Contains $pre.Output 'PRECHECK\s*=\s*PASS|BUILD PRECHECK = PASS|PREFLIGHT=PASS|PRECHECK = PASS' "STEP21_${TargetTier}_PRECHECK"
    Assert-Contains $pre.Output 'LIVE_MONEY_AUTHORIZED=False' "STEP21_${TargetTier}_LIVE_MONEY_LOCK_PRE"

    if ($Mode -eq 'PRECHECK') {
        return [pscustomobject]@{ Tier=$TargetTier; Precheck='PASS'; Demo='NOT_RUN'; Lifecycle='NOT_RUN' }
    }

    Write-Step21 "STEP21_${TargetTier}_DEMO=START"
    $demo = Invoke-PowerShellChild -Runner $runner -Arguments $demoArgs -Name ("{0}_demo" -f $TargetTier.ToLowerInvariant())
    if ($demo.ExitCode -ne 0) { throw "$TargetTier DEMO child exit=$($demo.ExitCode)" }

    Assert-Contains $demo.Output 'STEP19_SELECTED_TIER_LIFECYCLE=PASS|SELECTED-TIER LIFECYCLE = PASS|DEMO LIFECYCLE = PASS' "STEP21_${TargetTier}_LIFECYCLE"
    Assert-Contains $demo.Output 'ACTUAL_TIER_NO_WORSENING_SL=PASS' "STEP21_${TargetTier}_NO_WORSENING_SL"
    Assert-Contains $demo.Output 'ACTUAL_TIER_NORMAL_CLOSE=PASS' "STEP21_${TargetTier}_NORMAL_CLOSE"
    Assert-Contains $demo.Output 'DATABASE_RECONCILIATION_IDEMPOTENT=PASS' "STEP21_${TargetTier}_DB_RECONCILIATION"
    Assert-Contains $demo.Output 'BROKER_DATABASE_POSITION_AGREEMENT=PASS' "STEP21_${TargetTier}_BROKER_DB_AGREEMENT"
    Assert-Contains $demo.Output 'ZERO_RESIDUAL_EXPOSURE=PASS' "STEP21_${TargetTier}_ZERO_RESIDUAL_EXPOSURE"
    Assert-Contains $demo.Output 'PRODUCTION_IDEMPOTENCY_STORE_UNTOUCHED=PASS' "STEP21_${TargetTier}_PRODUCTION_IDEMPOTENCY_ISOLATION"
    Assert-Contains $demo.Output 'PROCESS_LOCAL_SETTINGS_RESTORED=PASS' "STEP21_${TargetTier}_PROCESS_SETTINGS_RESTORED"
    Assert-Contains $demo.Output 'PRODUCTION_ENV_CHANGED=False' "STEP21_${TargetTier}_ENV_RESTORED"
    Assert-Contains $demo.Output 'LIVE_MONEY_AUTHORIZED=False' "STEP21_${TargetTier}_LIVE_MONEY_LOCK_POST"

    return [pscustomobject]@{ Tier=$TargetTier; Precheck='PASS'; Demo='PASS'; Lifecycle='PASS' }
}

$certified = $false
$failure = ''
$results = @()
$step20Summary = $null
$envHashBefore = $null
$sourceHashesBefore = @{}

try {
    Write-Step21 '===================================================='
    Write-Step21 ' ABUTRON STEP 21 - CONTROLLED DEMO EXECUTION CERT'
    Write-Step21 " BUILD=$BuildMarker MODE=$Mode TIER=$Tier"
    Write-Step21 '===================================================='

    if (-not (Test-Path $EnvFile)) { throw "Missing $EnvFile" }
    if (-not (Test-Path $FlipperRunner)) { throw "Missing Step19 Flipper runner: $FlipperRunner" }
    if (-not (Test-Path $MultiRunner)) { throw "Missing Step19 multi-demo runner: $MultiRunner" }
    if (-not (Test-Path $MultiHelper)) { throw "Missing Step19 v1.4 helper: $MultiHelper" }

    if ($Mode -eq 'DEMO' -and -not $AuthorizeDemo) {
        throw 'DEMO mode requires explicit -AuthorizeDemo. Live-money authorization is never permitted by Step21.'
    }

    Assert-EnvFalse 'ABUTRON_EXECUTION_ENABLED'
    Assert-EnvFalse 'MT5_LIVE_TRADING'
    Assert-EnvFalse 'MT5_MANAGEMENT_ENABLED'
    Assert-EnvTrue 'MT5_DEMO_ONLY'

    $envHashBefore = (Get-FileHash $EnvFile -Algorithm SHA256).Hash.ToUpperInvariant()
    foreach ($p in @($FlipperRunner,$MultiRunner,$MultiHelper)) {
        $sourceHashesBefore[$p] = (Get-FileHash $p -Algorithm SHA256).Hash.ToUpperInvariant()
    }

    $step20Summary = Assert-Step20Prerequisite

    $workers = Get-WorkerCount
    if ($workers -ne 0) { throw "Production worker must be OFF for Step21; found $workers worker process(es)." }
    Write-Step21 'WORKER_BASELINE=OFF'

    Assert-LiveStackSafety

    $mt5Token = Get-EnvValue 'MT5_TOKEN'
    if (-not $mt5Token) { throw 'MT5_TOKEN missing; authenticated bridge verification cannot run.' }
    $headers = @{ Authorization = "Bearer $mt5Token" }
    $account = Invoke-JsonGet "$BridgeUrl/v1/account" $headers
    $positionsBefore = @(Invoke-JsonGet "$BridgeUrl/v1/positions" $headers)
    Write-Step21 'BRIDGE_AUTHENTICATED_READS=PASS'
    Write-Step21 ("MT5_ACCOUNT_SERVER={0}" -f $account.server)
    Write-Step21 ("TOTAL_POSITIONS_BASELINE={0}" -f $positionsBefore.Count)

    $targets = if ($Tier -eq 'ALL') { @('FLIPPER','SCALPER','MASTER') } else { @($Tier) }
    foreach ($t in $targets) {
        $login = 0
        if ($t -eq 'SCALPER') { $login = $ScalperLogin }
        if ($t -eq 'MASTER') { $login = $MasterLogin }
        $results += Invoke-TierCertification -TargetTier $t -CertLogin $login
    }

    if ((Get-FileHash $EnvFile -Algorithm SHA256).Hash.ToUpperInvariant() -ne $envHashBefore) {
        throw 'Production .env changed during Step21.'
    }
    Write-Step21 'STEP21_ENV_IMMUTABILITY=PASS'

    foreach ($p in $sourceHashesBefore.Keys) {
        if ((Get-FileHash $p -Algorithm SHA256).Hash.ToUpperInvariant() -ne $sourceHashesBefore[$p]) {
            throw "Certified Step19 dependency changed during Step21: $p"
        }
    }
    Write-Step21 'STEP21_DEPENDENCY_IMMUTABILITY=PASS'

    $workersFinal = Get-WorkerCount
    if ($workersFinal -ne 0) { throw "Production worker not OFF after Step21; found $workersFinal" }
    Write-Step21 'WORKER_FINAL=OFF'

    Assert-LiveStackSafety

    $positionsAfter = @(Invoke-JsonGet "$BridgeUrl/v1/positions" $headers)
    Write-Step21 ("TOTAL_POSITIONS_FINAL={0}" -f $positionsAfter.Count)
    Write-Step21 'STEP21_POSTRUN_BRIDGE_READ=PASS'

    $certified = $true
}
catch {
    $failure = $_.Exception.Message
    Write-Step21 ("STEP21_FAILURE={0}" -f $failure)
}
finally {
    $finishedUtc = [DateTime]::UtcNow
    $summary = [ordered]@{
        build_marker = $BuildMarker
        result = $(if ($certified) { if ($Mode -eq 'PRECHECK') {'PRECHECK_PASS'} else {'PASS'} } else {'FAIL'})
        mode = $Mode
        requested_tier = $Tier
        direction = $Direction
        started_utc = $StartedUtc.ToString('o')
        finished_utc = $finishedUtc.ToString('o')
        step20_summary = $step20Summary
        production_env_changed = $(if ($envHashBefore -and (Test-Path $EnvFile)) { ((Get-FileHash $EnvFile -Algorithm SHA256).Hash.ToUpperInvariant() -ne $envHashBefore) } else { $null })
        live_money_authorized = $false
        production_execution_enabled = $false
        production_live_trading = $false
        production_management_enabled = $false
        tiers = @($results)
        controller_log = $ControllerLog
        failure = $failure
    }
    $json = $summary | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($SummaryFile,$json,[System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($StableSummaryFile,$json,[System.Text.UTF8Encoding]::new($false))

    Write-Host ''
    Write-Host '===================================================='
    if ($certified) {
        if ($Mode -eq 'PRECHECK') { Write-Host ' STEP 21 CONTROLLED DEMO PRECHECK = PASS' }
        else { Write-Host ' STEP 21 CONTROLLED DEMO CERTIFICATION = PASS' }
        Write-Host '===================================================='
        Write-Host "STEP21_MODE=$Mode"
        Write-Host "STEP21_TIER=$Tier"
        Write-Host 'STEP21_ENV_IMMUTABILITY=PASS'
        Write-Host 'STEP21_DEPENDENCY_IMMUTABILITY=PASS'
        Write-Host 'WORKER_FINAL=OFF'
        Write-Host 'PRODUCTION_LIVE_TRADING=OFF'
        Write-Host 'PRODUCTION_MANAGEMENT=OFF'
        Write-Host 'ABUTRON_EXECUTION=OFF'
        Write-Host 'LIVE_MONEY_AUTHORIZED=False'
        if ($Mode -eq 'PRECHECK') { Write-Host 'STEP21=PRECHECK_PASS' } else { Write-Host 'STEP21=PASS' }
        Write-Host "STEP21_SUMMARY=$SummaryFile"
        Write-Host "STEP21_CONTROLLER_LOG=$ControllerLog"
        Write-Host '===================================================='
        exit 0
    } else {
        Write-Host ' STEP 21 = NOT CERTIFIED'
        Write-Host '===================================================='
        Write-Host "STEP21_FAILURE=$failure"
        Write-Host 'LIVE_MONEY_AUTHORIZED=False'
        Write-Host "STEP21_SUMMARY=$SummaryFile"
        Write-Host "STEP21_CONTROLLER_LOG=$ControllerLog"
        Write-Host '===================================================='
        exit 1
    }
}
