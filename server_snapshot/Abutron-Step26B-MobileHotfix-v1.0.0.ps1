param(
    [string]$Root = "C:\Abutron\TradingPlatformV4"
)

$ErrorActionPreference = "Stop"
$Mobile = Join-Path $Root "mobile\AbutronMobile"
$Api = Join-Path $Mobile "src\api.ts"
$App = Join-Path $Mobile "App.tsx"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Backup = Join-Path "C:\Abutron\Backups\Step26B-MobileHotfix" $Stamp

function Say([string]$m) {
    Write-Host "$(Get-Date -Format s) $m"
}

Say "STEP26B_MOBILE_HOTFIX_V1_0_0_START"

if(-not (Test-Path $Api)) { throw "API_TS_NOT_FOUND: $Api" }
if(-not (Test-Path $App)) { throw "APP_TSX_NOT_FOUND: $App" }

$health = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 15
if($health.status -ne "ok") { throw "LOCAL_API_HEALTH_FAIL" }
if($health.execution_enabled -ne $false) { throw "ABORT_EXECUTION_ENABLED" }
if($health.mt5.live_trading -ne $false) { throw "ABORT_LIVE_TRADING_ENABLED" }
if($health.mt5.management_enabled -ne $false) { throw "ABORT_MANAGEMENT_ENABLED" }
Say "STEP26B_HOTFIX_SAFETY_GATE=PASS"

New-Item -ItemType Directory -Force -Path $Backup | Out-Null
Copy-Item $Api (Join-Path $Backup "api.ts") -Force
Copy-Item $App (Join-Path $Backup "App.tsx") -Force
Say "STEP26B_HOTFIX_BACKUP=PASS:$Backup"

$apiText = Get-Content $Api -Raw

$oldApi = @'
  const response = await fetch(`${API_URL}${path}`, {...options, headers});
  const text = await response.text();
  let payload: any = {};
  try { payload = text ? JSON.parse(text) : {}; }
  catch { payload = {detail: text}; }

  if (!response.ok) {
    throw new Error(payload.detail || `Request failed (${response.status})`);
  }
  return payload as T;
'@

$newApi = @'
  let response: Response;
  try {
    response = await fetch(`${API_URL}${path}`, {...options, headers});
  } catch (error: any) {
    const raw = String(error?.message ?? error ?? "");
    if (/UnknownHostException|Unable to resolve host|Network request failed|Failed to fetch|ENOTFOUND|EAI_AGAIN/i.test(raw)) {
      throw new Error("No internet connection. Check your connection and try again.");
    }
    throw new Error("Unable to reach Abutron FX. Please try again.");
  }

  const text = await response.text();
  let payload: any = {};
  try { payload = text ? JSON.parse(text) : {}; }
  catch { payload = {detail: text}; }

  if (!response.ok) {
    const detail = payload?.detail;
    let message = "";

    if (typeof detail === "string") {
      message = detail;
    } else if (Array.isArray(detail)) {
      message = detail
        .map((item: any) => {
          const field = Array.isArray(item?.loc)
            ? item.loc.filter((x: any) => x !== "body").join(".")
            : "";
          const msg = typeof item?.msg === "string" ? item.msg : "Invalid value";
          return field ? `${field}: ${msg}` : msg;
        })
        .join(" ");
    } else if (detail && typeof detail === "object") {
      try { message = JSON.stringify(detail); }
      catch { message = "The request could not be completed."; }
    }

    throw new Error(message || `Request failed (${response.status})`);
  }

  return payload as T;
'@

if(-not $apiText.Contains($oldApi)) {
    throw "API_PATCH_TARGET_NOT_FOUND"
}
$apiText = $apiText.Replace($oldApi, $newApi)
[System.IO.File]::WriteAllText($Api, $apiText, [System.Text.UTF8Encoding]::new($false))
Say "STEP26B_API_ERROR_FORMATTER_PATCH=PASS"

$appText = Get-Content $App -Raw

$oldSupport = @'
  async function submit(){
    try{
      await request("/v1/support/tickets",{method:"POST",body:JSON.stringify({subject,message,priority:"normal"})});
      setSubject("");setMessage("");setStatus("Support ticket created.");await refresh();
    }catch(e:any){setStatus(e.message)}
  }
'@

$newSupport = @'
  async function submit(){
    const cleanSubject=subject.trim();
    const cleanMessage=message.trim();

    if(cleanSubject.length<3){
      setStatus("Subject must be at least 3 characters.");
      return;
    }
    if(cleanMessage.length<5){
      setStatus("Message must be at least 5 characters.");
      return;
    }

    try{
      setStatus("");
      await request("/v1/support/tickets",{
        method:"POST",
        body:JSON.stringify({
          subject:cleanSubject,
          message:cleanMessage,
          priority:"normal"
        })
      });
      setSubject("");
      setMessage("");
      setStatus("Support ticket created.");
      await refresh();
    }catch(e:any){
      setStatus(e?.message || "Unable to create support ticket. Please try again.");
    }
  }
'@

if(-not $appText.Contains($oldSupport)) {
    throw "SUPPORT_PATCH_TARGET_NOT_FOUND"
}
$appText = $appText.Replace($oldSupport, $newSupport)

$appText = $appText.Replace(
    '<Text style={styles.muted}>Step 26A · Customer Mobile</Text>',
    '<Text style={styles.muted}>Customer Mobile</Text>'
)

[System.IO.File]::WriteAllText($App, $appText, [System.Text.UTF8Encoding]::new($false))
Say "STEP26B_SUPPORT_VALIDATION_PATCH=PASS"
Say "STEP26B_CUSTOMER_LABEL_PATCH=PASS"

Set-Location $Mobile

& ".\node_modules\.bin\tsc.cmd" --noEmit
if($LASTEXITCODE -ne 0) { throw "TYPESCRIPT_CHECK_FAIL" }
Say "STEP26B_TYPESCRIPT=PASS"

npx expo-doctor@latest
if($LASTEXITCODE -ne 0) { throw "EXPO_DOCTOR_FAIL" }
Say "STEP26B_EXPO_DOCTOR=PASS"

$forbidden = @(
    "/v1/live",
    "/v1/manage",
    "/v1/close/",
    "/v1/evaluate",
    "order_send",
    "Place Order"
)

$hits = @()
foreach($term in $forbidden){
    $found = Get-ChildItem $Mobile -File -Recurse |
        Where-Object { $_.FullName -notmatch "\\node_modules\\" -and $_.FullName -notmatch "\\.git\\" } |
        Select-String -SimpleMatch $term -ErrorAction SilentlyContinue
    if($found){ $hits += $found }
}

if($hits.Count -gt 0){
    $hits | ForEach-Object { Write-Host $_ }
    throw "STEP26B_READ_ONLY_SOURCE_GUARD_FAIL"
}
Say "STEP26B_READ_ONLY_SOURCE_GUARD=PASS"

$health2 = Invoke-RestMethod "http://127.0.0.1:8088/health" -TimeoutSec 15
if($health2.execution_enabled -ne $false) { throw "FINAL_EXECUTION_ENABLED" }
if($health2.mt5.live_trading -ne $false) { throw "FINAL_LIVE_TRADING_ENABLED" }
if($health2.mt5.management_enabled -ne $false) { throw "FINAL_MANAGEMENT_ENABLED" }

Say "STEP26B_FINAL_SERVER_SAFETY=PASS"
Say "LIVE_MONEY_AUTHORIZED=False"

Write-Host ""
Write-Host "=== GIT DIFF ==="
git diff -- App.tsx src/api.ts

Write-Host ""
Write-Host "===================================================="
Write-Host " STEP26B MOBILE HOTFIX v1.0.0 = PASS" -ForegroundColor Green
Write-Host "===================================================="
Write-Host "Backup: $Backup"
Write-Host ""
Write-Host "Next:"
Write-Host '  git add App.tsx src/api.ts'
Write-Host '  git commit -m "Step26B mobile error handling and support validation"'
Write-Host '  npx eas-cli@latest build --platform android --profile preview'
