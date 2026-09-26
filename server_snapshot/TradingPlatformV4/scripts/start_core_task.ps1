$ErrorActionPreference = "Stop"

$root = "C:\Abutron\TradingPlatformV4"
$start = "$root\scripts\start_core.ps1"
$log = "$root\logs\core_system_task.log"

function Log-Line {
    param([string]$Text)

    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"

    "[$stamp] $Text" |
        Out-File `
            -FilePath $log `
            -Append `
            -Encoding UTF8
}

try {

    Log-Line "CORE_SYSTEM_WRAPPER_START"

    Log-Line ("IDENTITY=" + [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

    Log-Line ("ROOT_EXISTS=" + (Test-Path $root))
    Log-Line ("START_SCRIPT_EXISTS=" + (Test-Path $start))
    Log-Line ("VENV_PYTHON_EXISTS=" + (Test-Path "$root\.venv\Scripts\python.exe"))
    Log-Line ("ENV_FILE_EXISTS=" + (Test-Path "$root\.env"))

    $listener = Get-NetTCPConnection `
        -LocalPort 8088 `
        -State Listen `
        -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($listener) {
        Log-Line ("EXISTING_LISTENER_PID=" + $listener.OwningProcess)
        exit 0
    }

    if (-not (Test-Path $start)) {
        throw "Core startup script missing."
    }

    $source = Get-Content $start -Raw

    $forbiddenWorker = "abutron" + ".worker"
    $forbiddenLauncher = "start" + "_platform"

    if ($source -match [regex]::Escape($forbiddenWorker)) {
        throw "Worker reference found in Core startup."
    }

    if ($source -match [regex]::Escape($forbiddenLauncher)) {
        throw "Unsafe launcher reference found in Core startup."
    }

    Log-Line "STARTING_CORE"

    & $start *>> $log

    $code = $LASTEXITCODE

    Log-Line ("CORE_EXIT_CODE=" + $code)

    exit $code
}
catch {

    Log-Line ("ERROR_TYPE=" + $_.Exception.GetType().FullName)
    Log-Line ("ERROR_MESSAGE=" + $_.Exception.Message)
    Log-Line ("ERROR_POSITION=" + $_.InvocationInfo.PositionMessage)

    exit 1
}
