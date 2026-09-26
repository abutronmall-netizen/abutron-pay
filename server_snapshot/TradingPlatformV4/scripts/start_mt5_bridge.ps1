$ErrorActionPreference="Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
& ".\.venv\Scripts\python.exe" -m uvicorn mt5_bridge.app:app --host 127.0.0.1 --port 8090
