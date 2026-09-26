$ErrorActionPreference = "Stop"

$root = "C:\Abutron\TradingPlatformV4"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"

$start = "$root\scripts\start_mt5_bridge.ps1"

$listener = Get-NetTCPConnection `
    -LocalPort 8090 `
    -State Listen `
    -ErrorAction SilentlyContinue |
    Select-Object -First 1

if ($listener) {
    exit 0
}

$deadline = (Get-Date).AddMinutes(2)

do {
    $terminal = @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -ieq "terminal64.exe" -and
            $_.ExecutablePath -ieq $mt5Path
        }
    )

    if ($terminal.Count -gt 1) {
        throw "Multiple production MT5 terminals detected."
    }

    if ($terminal.Count -eq 1) {
        break
    }

    Start-Sleep -Seconds 2

} while ((Get-Date) -lt $deadline)

if ($terminal.Count -ne 1) {
    throw "Expected MT5 terminal did not appear."
}

if (-not (Test-Path $start)) {
    throw "Bridge startup script missing."
}

$content = Get-Content $start -Raw

$forbiddenWorker = "abutron" + ".worker"
$forbiddenLauncher = "start" + "_platform"

if ($content -match [regex]::Escape($forbiddenWorker)) {
    throw "Forbidden worker reference detected."
}

if ($content -match [regex]::Escape($forbiddenLauncher)) {
    throw "Forbidden launcher reference detected."
}

& $start

exit $LASTEXITCODE
