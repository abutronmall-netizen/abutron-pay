param([string]$Root="C:\Abutron\TradingPlatformV4")
$ErrorActionPreference="Stop"
$sd=Join-Path $Root "abutron"
$b=Get-ChildItem $sd -Filter "service.py.pre_step23q_*" -File|Sort-Object LastWriteTime -Descending|Select-Object -First 1
if(-not $b){throw "SERVICE_BACKUP_NOT_FOUND"}
Copy-Item $b.FullName (Join-Path $sd "service.py") -Force
$q=Join-Path $sd "quant";if(Test-Path $q){Remove-Item $q -Recurse -Force}
$e=Join-Path $Root ".env"
if(Test-Path $e){Get-Content $e|Where-Object{$_ -notmatch "^ABUTRON_QUANT_"}|Set-Content "$e.tmp";Move-Item "$e.tmp" $e -Force}
Write-Host "STEP23Q_ROLLBACK=PASS"
