# Step 21B v1.1.0 → v1.1.1 Repair

## Observed VPS failure
v1.1.0 passed all 16 gateway tests, then failed with:

```text
ModuleNotFoundError: No module named 'abutron'
STEP21B_CORE_IMPORT_FAIL
```

The installer invoked the existing Kronos Python environment while PowerShell's current directory was the Step 21B source folder. The `abutron` package lives under `C:\Abutron\TradingPlatformV4`.

## v1.1.1 correction
Core validation is executed inside:

```text
C:\Abutron\TradingPlatformV4
```

The installer also verifies the production `TradingService` is still using `MT5Gateway`, and it rolls back the Core/API/env files if a later install gate fails.

## Run

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Set-Location "C:\Abutron\Step21B-v111"
.\scripts\install_step21b.ps1
```

Then:

```powershell
Set-Location "C:\Abutron\TradingPlatformV4\ctrader_cloud_gateway"
.\scripts\step21b_precredential.ps1
```

Expected safety state:

```text
DEMO_EXECUTION_ENABLED=False
LIVE_MONEY_AUTHORIZED=False
KILL_SWITCH=True
BROKER_ORDER_SENT=False
```
