$ErrorActionPreference='Stop'
$env:PYTHONPATH='C:\Abutron\Jarvis\rc1_08'
$tokenLine=Get-Content 'C:\Abutron\Jarvis\.env' | Where-Object { $_ -match '^JARVIS_API_TOKEN=' } | Select-Object -First 1
if(-not $tokenLine){ throw 'JARVIS_API_TOKEN missing at runtime' }
$env:JARVIS_API_TOKEN=$tokenLine.Substring(17).Trim()
$env:HERMES_HOME='C:\Users\Administrator\AppData\Local\hermes'
& 'C:\Abutron\Jarvis\.venv\Scripts\python.exe' -m rc1_08.service --config 'C:\Abutron\Jarvis\rc1_08\config.json'
