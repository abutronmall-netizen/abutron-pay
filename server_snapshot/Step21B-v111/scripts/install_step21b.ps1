param([string]$Root='C:\Abutron\TradingPlatformV4')
$ErrorActionPreference='Stop'
$Source=Split-Path -Parent $PSScriptRoot
$Target=Join-Path $Root 'ctrader_cloud_gateway'
$Python=Join-Path $Root '.venv_ctrader\Scripts\python.exe'
$CorePython=Join-Path $Root '.venv\Scripts\python.exe'
$GatewayEnv=Join-Path $Target '.env'
$CoreEnv=Join-Path $Root '.env'
$ApiPath=Join-Path $Root 'abutron\api.py'
$CoreRoutesPath=Join-Path $Root 'abutron\ctrader_routes.py'
$CoreGatewayDir=Join-Path $Root 'abutron\gateways'
$CoreGatewayPath=Join-Path $CoreGatewayDir 'ctrader_cloud.py'

if (-not (Test-Path $Python)) { throw 'STEP21A_CTRADER_VENV_MISSING' }
if (-not (Test-Path $CorePython)) { throw 'ABUTRON_CORE_VENV_MISSING' }
if (-not (Test-Path $GatewayEnv)) { throw 'STEP21A_GATEWAY_ENV_MISSING' }
if (-not (Test-Path $ApiPath)) { throw 'ABUTRON_API_MISSING' }
if (-not (Test-Path $CoreEnv)) { throw 'ABUTRON_CORE_ENV_MISSING' }

Write-Host '===================================================='
Write-Host ' ABUTRON STEP 21B V1.1.1 - IC MARKETS OAUTH/DISCOVERY'
Write-Host ' CORE IMPORT REPAIR - ZERO ORDER / READ ONLY'
Write-Host '===================================================='

$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$backup=Join-Path $Root ("backups\step21b_v111_"+$stamp)
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Copy-Item $ApiPath (Join-Path $backup 'api.py') -Force
Copy-Item $CoreEnv (Join-Path $backup 'core.env') -Force
Copy-Item $GatewayEnv (Join-Path $backup 'ctrader.env') -Force
if(Test-Path $CoreRoutesPath){ Copy-Item $CoreRoutesPath (Join-Path $backup 'ctrader_routes.py') -Force }
if(Test-Path $CoreGatewayPath){ Copy-Item $CoreGatewayPath (Join-Path $backup 'ctrader_cloud.py') -Force }

function Restore-Step21BBackup {
    Write-Host 'STEP21B_ROLLBACK=START'
    Copy-Item (Join-Path $backup 'api.py') $ApiPath -Force
    Copy-Item (Join-Path $backup 'core.env') $CoreEnv -Force
    Copy-Item (Join-Path $backup 'ctrader.env') $GatewayEnv -Force
    $bRoutes=Join-Path $backup 'ctrader_routes.py'
    $bGateway=Join-Path $backup 'ctrader_cloud.py'
    if(Test-Path $bRoutes){ Copy-Item $bRoutes $CoreRoutesPath -Force }
    elseif(Test-Path $CoreRoutesPath){ Remove-Item $CoreRoutesPath -Force }
    if(Test-Path $bGateway){ Copy-Item $bGateway $CoreGatewayPath -Force }
    elseif(Test-Path $CoreGatewayPath){ Remove-Item $CoreGatewayPath -Force }
    Write-Host 'STEP21B_ROLLBACK=PASS'
}

try {
    # Preserve actual gateway .env and SQLite binding data while replacing Step 21B source files.
    $tempEnv=Join-Path $env:TEMP ("abutron_ctrader_env_"+[guid]::NewGuid().ToString()+'.tmp')
    Copy-Item $GatewayEnv $tempEnv -Force
    $tempDb=$null
    $dbPath=Join-Path $Target 'data\ctrader_gateway.db'
    if(Test-Path $dbPath){
        $tempDb=Join-Path $env:TEMP ("abutron_ctrader_db_"+[guid]::NewGuid().ToString()+'.db')
        Copy-Item $dbPath $tempDb -Force
    }

    foreach($name in @('ctrader_gateway','core_integration','requirements.txt','.env.example','README.md','MANIFEST.json','STEP21B_BUILD_REPORT.json','docs','tests','deployment','scripts')){
        $src=Join-Path $Source $name
        if(-not(Test-Path $src)){throw "SOURCE_ARTIFACT_MISSING:$name"}
        Copy-Item $src $Target -Recurse -Force
    }
    Copy-Item $tempEnv $GatewayEnv -Force
    Remove-Item $tempEnv -Force
    if($tempDb){
        New-Item -ItemType Directory -Force -Path (Split-Path $dbPath -Parent)|Out-Null
        Copy-Item $tempDb $dbPath -Force
        Remove-Item $tempDb -Force
    }

    # Validate gateway package before touching Abutron Core.
    Push-Location $Target
    try {
        & $Python -m compileall -q ctrader_gateway core_integration
        if($LASTEXITCODE -ne 0){throw 'STEP21B_COMPILE_FAIL'}
        & $Python -m pytest -q tests
        if($LASTEXITCODE -ne 0){throw 'STEP21B_TEST_FAIL'}
    } finally { Pop-Location }

    # Safety defaults must remain closed in the preserved runtime env.
    $g=Get-Content $GatewayEnv -Raw
    foreach($x in @('CTRADER_ENABLE_LIVE_CONNECTION=false','CTRADER_DEMO_EXECUTION_ENABLED=false','CTRADER_LIVE_MONEY_AUTHORIZED=false','CTRADER_KILL_SWITCH=true')){
        if($g -notmatch [regex]::Escape($x)){throw "STEP21B_SAFETY_GATE_FAIL:$x"}
    }

    # Install additive Core-side adapter/router. TradingService execution selection is NOT changed.
    New-Item -ItemType Directory -Force -Path $CoreGatewayDir|Out-Null
    Copy-Item (Join-Path $Target 'core_integration\ctrader_cloud.py') $CoreGatewayPath -Force
    Copy-Item (Join-Path $Target 'core_integration\ctrader_routes.py') $CoreRoutesPath -Force

    # Synchronize localhost gateway URL + internal key; never print the key.
    $keyLine=(Get-Content $GatewayEnv | Where-Object {$_ -match '^CTRADER_INTERNAL_API_KEY='} | Select-Object -First 1)
    if(-not $keyLine){throw 'CTRADER_INTERNAL_API_KEY_MISSING'}
    $key=$keyLine.Substring($keyLine.IndexOf('=')+1)
    if([string]::IsNullOrWhiteSpace($key)){throw 'CTRADER_INTERNAL_API_KEY_EMPTY'}
    $core=Get-Content $CoreEnv -Raw
    if($core -match '(?m)^ABUTRON_CTRADER_GATEWAY_URL='){$core=[regex]::Replace($core,'(?m)^ABUTRON_CTRADER_GATEWAY_URL=.*$','ABUTRON_CTRADER_GATEWAY_URL=http://127.0.0.1:8091')}
    else{$core += "`r`nABUTRON_CTRADER_GATEWAY_URL=http://127.0.0.1:8091`r`n"}
    if($core -match '(?m)^ABUTRON_CTRADER_GATEWAY_INTERNAL_KEY='){$core=[regex]::Replace($core,'(?m)^ABUTRON_CTRADER_GATEWAY_INTERNAL_KEY=.*$',('ABUTRON_CTRADER_GATEWAY_INTERNAL_KEY='+$key))}
    else{$core += ('ABUTRON_CTRADER_GATEWAY_INTERNAL_KEY='+$key+"`r`n")}
    Set-Content $CoreEnv $core -Encoding UTF8

    # Add router idempotently.
    $api=Get-Content $ApiPath -Raw
    $import='from abutron.ctrader_routes import router as ctrader_router'
    $include='app.include_router(ctrader_router)'
    if($api -notmatch [regex]::Escape($import)){
        $needle='from abutron.security import hash_password,verify_password,issue_token,current_user,require_admin'
        if($api -notmatch [regex]::Escape($needle)){throw 'STEP21B_API_PATCH_ANCHOR_MISSING'}
        $api=$api -replace [regex]::Escape($needle),($needle+"`r`n"+$import)
    }
    if($api -notmatch [regex]::Escape($include)){
        $api += "`r`n# Step 21B: customer-authenticated IC Markets cTrader account linking (zero-order).`r`n$include`r`n"
    }
    Set-Content $ApiPath $api -Encoding UTF8

    # Critical v1.1.1 fix: validate the Core from its real project working directory.
    # Abutron imports and pydantic .env resolution depend on C:\Abutron\TradingPlatformV4 being on sys.path/CWD.
    Push-Location $Root
    try {
        & $CorePython -m py_compile $ApiPath $CoreRoutesPath $CoreGatewayPath
        if($LASTEXITCODE -ne 0){throw 'STEP21B_CORE_SYNTAX_FAIL'}

        $routes=& $CorePython -c "import os,sys; assert os.getcwd()==r'$Root'; from abutron.api import app; print('\\n'.join(sorted(r.path for r in app.routes)))"
        if($LASTEXITCODE -ne 0){throw 'STEP21B_CORE_IMPORT_FAIL'}
    } finally { Pop-Location }

    foreach($route in @('/v1/broker/ic-markets/connect','/v1/broker/ic-markets/accounts','/v1/broker/ic-markets/accounts/refresh','/v1/broker/ic-markets/accounts/{account_id}/discovery')){
        if($routes -notcontains $route){throw "STEP21B_ROUTE_MISSING:$route"}
    }

    # Reconfirm execution architecture is unchanged: TradingService still imports/instantiates MT5Gateway.
    $servicePath=Join-Path $Root 'abutron\service.py'
    $service=Get-Content $servicePath -Raw
    if($service -notmatch 'from abutron\.gateways\.mt5 import MT5Gateway'){throw 'STEP21B_EXECUTION_PATH_UNEXPECTED'}
    if($service -notmatch 'self\.gateway\s*=\s*MT5Gateway\(\)'){throw 'STEP21B_EXECUTION_PATH_UNEXPECTED'}

    Write-Host 'STEP21B_INSTALL=PASS'
    Write-Host 'STEP21B_V1_1_0_PARTIAL_INSTALL_REPAIRED=TRUE'
    Write-Host 'STEP21A_PREREQUISITE=PASS'
    Write-Host 'CUSTOMER_AUTH_ROUTE_BINDING=PASS'
    Write-Host 'CTRADER_OAUTH_ROUTE=PASS'
    Write-Host 'CTRADER_DISCOVERY_ROUTE=PASS'
    Write-Host 'CORE_IMPORT_WORKDIR=PASS'
    Write-Host 'Kronos_TradingService_EXECUTION_PATH_CHANGED=False'
    Write-Host 'DEMO_EXECUTION_ENABLED=False'
    Write-Host 'LIVE_MONEY_AUTHORIZED=False'
    Write-Host 'KILL_SWITCH=True'
    Write-Host 'BROKER_ORDER_SENT=False'
    Write-Host 'NEXT=RUN_STEP21B_PRECREDENTIAL'
}
catch {
    Restore-Step21BBackup
    throw
}
