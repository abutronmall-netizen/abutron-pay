$ErrorActionPreference = "Stop"
$Base = "C:\Abutron\Jarvis"
$Root = Join-Path $Base "rc1_09"
$Python = "C:\Abutron\Jarvis\.venv\Scripts\python.exe"
if(-not(Test-Path $Python)) {
    $Python = (Get-Command python.exe -ErrorAction Stop).Source
}
$env:PYTHONPATH = $Root
Set-Location $Root
& $Python -m rc1_09.service
