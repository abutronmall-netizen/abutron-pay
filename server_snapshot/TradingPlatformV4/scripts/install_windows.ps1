param([switch]$UsePostgres,[switch]$SkipKronosDownload)
$ErrorActionPreference='Stop'
$Root=Split-Path $PSScriptRoot -Parent
Set-Location $Root
function Need($name,$message){ if(!(Get-Command $name -ErrorAction SilentlyContinue)){ throw $message } }
function New-Secret([int]$bytes=36){ $b=New-Object byte[] $bytes; [Security.Cryptography.RandomNumberGenerator]::Fill($b); [Convert]::ToBase64String($b).Replace('/','_').Replace('+','-').TrimEnd('=') }
Need py "Install Python 3.11 x64 first."
Need git "Install Git for Windows first."
New-Item -ItemType Directory -Force -Path data,logs,vendor | Out-Null
if(!(Test-Path '.venv')) { py -3.11 -m venv .venv }
& '.\.venv\Scripts\python.exe' -m pip install --upgrade pip
& '.\.venv\Scripts\pip.exe' install -r requirements-core.txt
& '.\.venv\Scripts\pip.exe' install -r requirements-mt5.txt
if(!(Test-Path '.env')) {
  Copy-Item '.env.example' '.env'
  $api=New-Secret; $mt5=New-Secret; $jwt=New-Secret 48; $admin=New-Secret 24; $pg=New-Secret 24
  $c=Get-Content '.env' -Raw
  $c=$c.Replace('CHANGE_ME_LONG_RANDOM_TOKEN',$api).Replace('CHANGE_ME_DIFFERENT_LONG_RANDOM_TOKEN',$mt5).Replace('CHANGE_ME_JWT_SECRET_AT_LEAST_32_CHARS',$jwt).Replace('CHANGE_ME_ADMIN_PASSWORD',$admin)
  if($UsePostgres){
    Need docker "Docker Desktop/Engine is required with -UsePostgres."
    if($c -notmatch 'POSTGRES_PASSWORD='){ $c += "`r`nPOSTGRES_PASSWORD=$pg`r`n" }
    $c=$c.Replace('ABUTRON_PLATFORM_DB_URL=sqlite:///./data/abutron_platform.db',"ABUTRON_PLATFORM_DB_URL=postgresql+psycopg://abutron:$pg@127.0.0.1:5432/abutron")
    Set-Content '.env' $c -Encoding UTF8
    docker compose up -d postgres redis
  } else { Set-Content '.env' $c -Encoding UTF8 }
  @("ADMIN_EMAIL=admin@localhost","ADMIN_PASSWORD=$admin","ABUTRON_API_TOKEN=$api","MT5_API_TOKEN=$mt5") | Set-Content 'FIRST_RUN_SECRETS.txt'
  Write-Warning "FIRST_RUN_SECRETS.txt contains first-run credentials. Store securely, then delete it."
}
if(!$SkipKronosDownload){
  & "$PSScriptRoot\fetch_kronos.ps1"
  & '.\.venv\Scripts\python.exe' '.\scripts\download_models.py'
}
& '.\.venv\Scripts\python.exe' -m compileall -q abutron mt5_bridge
& '.\.venv\Scripts\python.exe' -m pytest -q
Write-Host "ABUTRON TRADING PLATFORM v4.0 installed." -ForegroundColor Green
Write-Host "Safety defaults remain OFF: ABUTRON_EXECUTION_ENABLED=false and MT5_LIVE_TRADING=false and MT5_MANAGEMENT_ENABLED=false"
