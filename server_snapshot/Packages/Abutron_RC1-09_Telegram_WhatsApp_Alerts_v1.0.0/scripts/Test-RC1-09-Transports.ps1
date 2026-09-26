param([switch]$Telegram,[switch]$WhatsApp)
$ErrorActionPreference="Stop"
$Root="C:\Abutron\Jarvis\rc1_09"
$Py="C:\Abutron\Jarvis\.venv\Scripts\python.exe"; if(-not(Test-Path $Py)){$Py=(Get-Command python.exe).Source}
$env:PYTHONPATH=$Root
$h=Invoke-RestMethod "http://127.0.0.1:8789/health"
if($h.mode -ne "NOTIFY_ONLY" -or $h.actions_enabled -ne $false){throw "RC1-09 safety contract failed"}
if(-not $Telegram -and -not $WhatsApp){$Telegram=$true;$WhatsApp=$true}
if($Telegram){
  & $Py -m rc1_09.cli enqueue-test --channel telegram --wait 45
  if($LASTEXITCODE -ne 0){throw "Telegram certification send failed"}
  Write-Host "PASS Telegram send + delivery audit" -ForegroundColor Green
}
if($WhatsApp){
  & $Py -m rc1_09.cli enqueue-test --channel whatsapp --wait 45
  if($LASTEXITCODE -ne 0){throw "WhatsApp API acceptance + delivery audit failed"}
  Write-Host "PASS WhatsApp API accepted message" -ForegroundColor Green
  Write-Host "NOTE: final delivered/read status is updated by Meta webhook when configured."
}
