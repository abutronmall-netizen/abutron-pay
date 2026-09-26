param([string]$CaddyFile="C:\caddy\Caddyfile",[string]$CaddyExe="C:\caddy\caddy.exe")
$ErrorActionPreference="Stop"
$marker="# RC1-09 WHATSAPP DELIVERY WEBHOOK"
if(-not(Test-Path $CaddyFile)){throw "Caddyfile not found"}
if(-not(Test-Path $CaddyExe)){throw "caddy.exe not found"}
$current=Get-Content $CaddyFile -Raw
if($current -match [regex]::Escape($marker)){
  Write-Host "RC1-09 webhook route already present"; exit 0
}
$needle="    # Default deny: future routes are private until deliberately allowlisted."
if(-not $current.Contains($needle)){throw "Default-deny marker not found; refusing automatic patch"}
$block=@"

    $marker
    @rc109_whatsapp_webhook {
        path /v1/notifications/whatsapp/webhook*
        method GET POST
    }
    handle @rc109_whatsapp_webhook {
        reverse_proxy 127.0.0.1:8789
    }

"@
$candidate=$current.Replace($needle,$block+$needle)
$stamp=Get-Date -Format "yyyyMMdd-HHmmss"
$backup="$CaddyFile.pre-rc1-09-$stamp"
$tmp="$CaddyFile.rc1-09-candidate-$stamp"
Set-Content $tmp $candidate -Encoding UTF8
& $CaddyExe validate --config $tmp --adapter caddyfile
if($LASTEXITCODE -ne 0){throw "Candidate Caddy validation failed"}
Copy-Item $CaddyFile $backup -Force
Copy-Item $tmp $CaddyFile -Force
try{
  & $CaddyExe validate --config $CaddyFile --adapter caddyfile
  if($LASTEXITCODE -ne 0){throw "Active Caddy validation failed"}
  & $CaddyExe reload --config $CaddyFile --adapter caddyfile
  if($LASTEXITCODE -ne 0){throw "Caddy reload failed"}
}catch{
  Copy-Item $backup $CaddyFile -Force
  & $CaddyExe reload --config $CaddyFile --adapter caddyfile
  throw
}
# Prove trading/admin endpoints remain denied publicly.
foreach($p in @("/v1/evaluate","/v1/admin/summary","/openapi.json","/health")){
  try{$r=Invoke-WebRequest ("https://api.abutronfx.online"+$p) -UseBasicParsing -TimeoutSec 20; $code=[int]$r.StatusCode}
  catch{ if($_.Exception.Response){$code=[int]$_.Exception.Response.StatusCode}else{throw}}
  if($code -ne 404){throw "Safety fail: public blocked route $p returned $code"}
}
Write-Host "PASS Caddy RC1-09 webhook route installed; public trading/admin default-deny preserved" -ForegroundColor Green
Write-Host "Backup=$backup"
Write-Host "META_CALLBACK_URL=https://api.abutronfx.online/v1/notifications/whatsapp/webhook"
