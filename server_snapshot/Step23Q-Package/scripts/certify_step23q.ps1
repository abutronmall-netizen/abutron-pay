param([string]$Root="C:\Abutron\TradingPlatformV4")
$ErrorActionPreference="Stop";Set-Location $Root
$Stamp=Get-Date -Format "yyyyMMdd-HHmmss";$Dir="$Root\certification\step23q";New-Item -ItemType Directory -Force -Path $Dir|Out-Null
$service=Get-Content ".\abutron\service.py" -Raw;$envText=Get-Content ".\.env" -Raw
$checks=[ordered]@{
 quant_import=$service.Contains("from abutron.quant.engine import QuantEngine")
 quant_stage=$service.Contains('"QUANTITATIVE MATHEMATICS"')
 quant_payload=$service.Contains('"quant":quant.to_dict()')
 thesis_unchanged=$service.Contains("thesis=create_thesis(symbol,kronos,features,mode,min_conf)")
 risk_unchanged=$service.Contains("risk=self.risk.evaluate(thesis,account,broker,bundle,tier=tier)")
 capital_present=$service.Contains("plan=make_order_plan(")
 execution_guard=$service.Contains("if execute and settings.execution_enabled and result.plan:")
}
$health=$null;try{$health=Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 10}catch{}
$shadow=$envText -match "(?m)^ABUTRON_QUANT_MODE=SHADOW\s*$"
$liveSafe=($envText -notmatch "ABUTRON_EXECUTION_ENABLED=true" -and $envText -notmatch "MT5_LIVE_TRADING=true" -and $envText -notmatch "MT5_MANAGEMENT_ENABLED=true" -and $envText -notmatch "LIVE_MONEY_AUTHORIZED=true")
$forbidden=Select-String -Path ".\abutron\quant\*.py" -Pattern "order_send|gateway\.order|MT5Gateway|RiskEngine|make_order_plan|route_with_position_lock" -CaseSensitive:$false -ErrorAction SilentlyContinue
$pass=(@($checks.Values|Where-Object{$_ -ne $true}).Count -eq 0 -and $shadow -and $liveSafe -and @($forbidden).Count -eq 0 -and ($null -eq $health -or $health.execution_enabled -eq $false))
$result=if($pass){"PASS"}else{"FAIL"}
$report="$Dir\STEP23Q_CERTIFICATION_$Stamp.json"
[ordered]@{version="1.0.0";step="23Q";mode="SHADOW";contract=$checks;env_shadow=$shadow;live_safety=$liveSafe;forbidden_reference_count=@($forbidden).Count;api_health=if($health){$health.status}else{"NOT_RUNNING"};result=$result}|ConvertTo-Json -Depth 8|Set-Content $report
Write-Host "STEP23Q_MODE=SHADOW"
Write-Host "STEP23Q_NO_EXECUTION_REFERENCE=$(if(@($forbidden).Count -eq 0){'PASS'}else{'FAIL'})"
Write-Host "STEP23Q_LIVE_SAFETY=$(if($liveSafe){'PASS'}else{'FAIL'})"
Write-Host "STEP23Q=$result"
Write-Host "STEP23Q_REPORT=$report"
if(-not $pass){exit 2}
