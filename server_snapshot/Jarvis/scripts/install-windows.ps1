$ErrorActionPreference="Stop"
$R="C:\Abutron\Jarvis"
foreach($p in @($R,"$R\logs","$R\data","C:\Abutron\Kronos-Dev","C:\Abutron\Kronos-Test")){New-Item -ItemType Directory -Force $p|Out-Null}
if(-not(Get-Command py -ErrorAction SilentlyContinue)){throw "Python 3.11+ required"}
if(-not(Get-Command git -ErrorAction SilentlyContinue)){throw "Git required"}
Set-Location $R
py -3 -m venv .venv
& "$R\.venv\Scripts\python.exe" -m pip install --upgrade pip
& "$R\.venv\Scripts\pip.exe" install -e ".[dev]"
if(-not(Get-Command hermes -ErrorAction SilentlyContinue)){iex (irm https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.ps1)}
Write-Host "Base installed. Copy .env.example to .env; run hermes setup; then hermes whatsapp-cloud; then scripts\preflight.ps1" -ForegroundColor Green
