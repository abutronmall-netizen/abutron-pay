param([string]$JarvisRoot="C:\Abutron\Jarvis",[string]$HermesHome="C:\Users\Administrator\AppData\Local\hermes")
$ErrorActionPreference='Stop'; $Pkg=Split-Path -Parent $PSScriptRoot; $Target=Join-Path $JarvisRoot 'rc1_08'; $Backup=Join-Path $JarvisRoot ("backups\rc1_08_"+(Get-Date -Format 'yyyyMMdd-HHmmss'))
if(!(Test-Path $JarvisRoot)){throw "Jarvis root missing"}; $Py=Join-Path $JarvisRoot '.venv\Scripts\python.exe'; if(!(Test-Path $Py)){throw 'Jarvis venv missing'}; $Hx=Join-Path $HermesHome 'bin\hermes.exe'; if(!(Test-Path $Hx)){throw 'Hermes missing'}
New-Item -ItemType Directory -Force $Backup|Out-Null; if(Test-Path $Target){Copy-Item $Target $Backup -Recurse -Force}; New-Item -ItemType Directory -Force $Target|Out-Null; Copy-Item (Join-Path $Pkg 'src\rc1_08') $Target -Recurse -Force; Copy-Item (Join-Path $Pkg 'config.example.json') (Join-Path $Target 'config.json') -Force; Copy-Item (Join-Path $Pkg 'README.md') $Target -Force
$cfgp=Join-Path $Target 'config.json'; $cfg=Get-Content $cfgp -Raw|ConvertFrom-Json; $cfg.hermes.exe=$Hx; $cfg.hermes.home=$HermesHome; $cfg|ConvertTo-Json -Depth 20|Set-Content $cfgp -Encoding UTF8
$envp=Join-Path $JarvisRoot '.env'; if(!(Test-Path $envp)){throw '.env missing'}; $line=Get-Content $envp|?{$_ -match '^JARVIS_API_TOKEN='}|Select-Object -First 1; if(!$line){throw 'JARVIS_API_TOKEN missing'}; $tok=$line.Substring(17).Trim(); if($tok.Length -lt 20 -or $tok -eq 'CHANGE_ME'){throw 'Rotate weak/default JARVIS_API_TOKEN first'}
$run=Join-Path $Target 'run-rc1-08.ps1'; @"
`$ErrorActionPreference='Stop'
`$env:PYTHONPATH='$Target'
`$tokenLine=Get-Content '$envp' | Where-Object { `$_ -match '^JARVIS_API_TOKEN=' } | Select-Object -First 1
if(-not `$tokenLine){ throw 'JARVIS_API_TOKEN missing at runtime' }
`$env:JARVIS_API_TOKEN=`$tokenLine.Substring(17).Trim()
`$env:HERMES_HOME='$HermesHome'
& '$Py' -m rc1_08.service --config '$cfgp'
"@|Set-Content $run -Encoding UTF8
$env:PYTHONPATH=$Target; & $Py -m py_compile (Join-Path $Target 'rc1_08\service.py') (Join-Path $Target 'rc1_08\engine.py') (Join-Path $Target 'rc1_08\store.py'); & $Hx --version|Out-Null
$action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$run`"" -WorkingDirectory $Target; $trigger=New-ScheduledTaskTrigger -AtStartup; $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero); Register-ScheduledTask -TaskName 'Abutron-Jarvis-RC1-08' -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force|Out-Null; Start-ScheduledTask 'Abutron-Jarvis-RC1-08'; Start-Sleep 5; $h=Invoke-RestMethod 'http://127.0.0.1:8788/health' -TimeoutSec 10; if($h.status -ne 'ok' -or $h.mode -ne 'OBSERVE_ONLY'){throw 'RC1-08 health failed'}; Write-Host 'RC1-08 installed: healthy OBSERVE_ONLY'; Write-Host "Config: $cfgp"; Write-Host "Backup: $Backup"
