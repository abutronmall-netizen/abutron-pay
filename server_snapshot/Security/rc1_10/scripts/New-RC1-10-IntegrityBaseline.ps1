$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "..\lib\RC1-10.Common.ps1")

Assert-RC10Administrator
Assert-RC10ReleaseSafety | Out-Null
$policy = Get-RC10Policy
New-Item -ItemType Directory -Force -Path $script:RC10Integrity | Out-Null
& icacls $script:RC10Integrity /inheritance:r /grant:r "Administrators:(OI)(CI)F" "SYSTEM:(OI)(CI)F" | Out-Null

$entries = @()
foreach($p in @($policy.integrity_file_candidates)) {
    if(Test-Path $p) {
        $entries += [pscustomobject]@{type="FILE";name=$p;sha256=(Get-FileHash $p -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
}
foreach($root in @($policy.integrity_roots)) {
    if(Test-Path $root.path) {
        foreach($pattern in @($root.patterns)) {
            foreach($f in Get-ChildItem $root.path -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue) {
                if($f.FullName -notmatch "\\__pycache__\\") {
                    $entries += [pscustomobject]@{type="FILE";name=$f.FullName;sha256=(Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
                }
            }
        }
    }
}
foreach($taskName in @($policy.critical_tasks)) {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($task) {
        $xml = Export-ScheduledTask -TaskName $taskName
        $entries += [pscustomobject]@{type="TASK";name=$taskName;sha256=(Get-RC10HashString $xml)}
    }
}

$entries = $entries | Sort-Object type,name -Unique
$manifest = [ordered]@{
    version="1.0.0"
    created_utc=(Get-Date).ToUniversalTime().ToString("o")
    entry_count=$entries.Count
    entries=$entries
}
$manifestPath = Join-Path $script:RC10Integrity "manifest.json"
$manifestJson = $manifest | ConvertTo-Json -Depth 20
$manifestJson | Set-Content $manifestPath -Encoding UTF8

$key = New-Object byte[] 32
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($key) } finally { $rng.Dispose() }
$protected = Protect-RC10Bytes $key
$keyPath = Join-Path $script:RC10Integrity "hmac_key.dpapi"
[IO.File]::WriteAllBytes($keyPath,$protected)

$h = [System.Security.Cryptography.HMACSHA256]::new($key)
try {
    $bytes = [Text.Encoding]::UTF8.GetBytes((Get-Content $manifestPath -Raw))
    $sig = $h.ComputeHash($bytes)
    $sigHex = (($sig | ForEach-Object { $_.ToString("x2") }) -join "")
} finally { $h.Dispose() }
$sigPath = Join-Path $script:RC10Integrity "manifest.hmac"
Set-Content $sigPath $sigHex -Encoding ASCII

Write-Host "RC1_10_INTEGRITY_BASELINE=PASS" -ForegroundColor Green
Write-Host "ENTRIES=$($entries.Count)"
Write-Host "MANIFEST=$manifestPath"
