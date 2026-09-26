$ErrorActionPreference = "Stop"

$mt5Path = "C:\Abutron\MT5\accounts\2f1938f3-e1a4-49b5-9211-2a505c663166\terminal64.exe"
$mt5Dir = Split-Path $mt5Path -Parent

$running = @(
    Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -ieq "terminal64.exe" -and
        $_.ExecutablePath -ieq $mt5Path
    }
)

if ($running.Count -gt 1) {
    throw "Multiple production MT5 terminals detected."
}

if ($running.Count -eq 1) {
    exit 0
}

if (-not (Test-Path $mt5Path)) {
    throw "Production MT5 terminal missing."
}

Start-Process `
    -FilePath $mt5Path `
    -ArgumentList "/portable" `
    -WorkingDirectory $mt5Dir

$deadline = (Get-Date).AddSeconds(60)

do {
    Start-Sleep -Seconds 2

    $running = @(
        Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -ieq "terminal64.exe" -and
            $_.ExecutablePath -ieq $mt5Path
        }
    )

    if ($running.Count -gt 1) {
        throw "Multiple production MT5 terminals detected."
    }

} while ($running.Count -ne 1 -and (Get-Date) -lt $deadline)

if ($running.Count -ne 1) {
    throw "MT5 terminal failed to start."
}

exit 0
